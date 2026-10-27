import Foundation

public enum Grade: String, Codable, Sendable {
    case A
    case B
    case C
}

public struct PlanHeader: Equatable, Sendable {
    public var project: String
    public var category: String
    public var branch: String
    public var commit: String
    public var appVersion: String
    public var dirty: Bool
}

public struct Scenario: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var platform: String
    public var grade: Grade
    public var gradeNote: String?
    public var account: String
    /// `계정` 칸의 첫 백틱 역할 키(project.yaml `accounts`의 키). 없으면 nil.
    public var accountRoleKey: String? = nil
    public var precondition: String?
    public var goal: String
    public var passCondition: String?
    public var evidence: String?
    public var runOptionsNote: String?
    public var dependsOn: [String]
}

public struct PlanDocument: Sendable {
    public let url: URL
    public private(set) var text: String
    public let header: PlanHeader
    public let scenarios: [Scenario]
    public let commonRunOptions: [String: String]
    public let accountEnvKeys: [String]

    public static func load(_ url: URL) throws -> PlanDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = parseHeader(lines)
        let commonRunOptions = parseCommonRunOptions(lines)
        let accountEnvKeys = parseAccountEnvKeys(lines)
        var scenarios = parseScenarios(lines)
        let scenarioIDs = Set(scenarios.map(\.id))

        for index in scenarios.indices {
            let currentID = scenarios[index].id
            let candidates = scenarioIDsIn(scenarios[index].title)
                + scenarioIDsIn(scenarios[index].precondition ?? "")
            var seen: Set<String> = []
            scenarios[index].dependsOn = candidates.filter { id in
                id != currentID && scenarioIDs.contains(id) && seen.insert(id).inserted
            }
        }

        return PlanDocument(
            url: url,
            text: text,
            header: header,
            scenarios: scenarios,
            commonRunOptions: commonRunOptions,
            accountEnvKeys: accountEnvKeys
        )
    }

    public func runOptions(for scenario: Scenario) -> [String: String] {
        guard let note = scenario.runOptionsNote else {
            return commonRunOptions
        }

        var options = commonRunOptions
        for value in Self.backtickValues(in: note) {
            if let separator = value.firstIndex(of: "=") {
                let key = String(value[..<separator])
                let optionValue = String(value[value.index(after: separator)...])
                options[key] = optionValue
            } else if note.contains("`\(value)` 빼고") {
                options[value] = nil
            }
        }
        return options
    }

    /// 선택한 시나리오에 필요한 `.env` 키. 로그인하는 시나리오가 모두 `roles`에 있는 역할 키를 가지면
    /// 그 역할들의 키만(나온 순서·중복 제거), 하나라도 없으면 준비 절의 `accountEnvKeys` 전체를 돌려준다.
    /// `계정` 칸에 "로그아웃 상태"가 있는 시나리오는 키가 필요 없다.
    public func requiredEnvKeys(for scenarios: [Scenario], roles: [String: AccountRole]) -> [String] {
        if usesAllAccountKeys(for: scenarios, roles: roles) {
            return accountEnvKeys
        }
        var keys: [String] = []
        for scenario in scenarios where Self.needsLogin(scenario) {
            guard let roleKey = scenario.accountRoleKey, let role = roles[roleKey] else { continue }
            for key in [role.idEnv, role.passwordEnv] where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    /// 로그인하는 시나리오 중 `roles`에 있는 역할 키가 없는 것이 있으면 true(계정 키 전체로 돌아간다).
    public func usesAllAccountKeys(for scenarios: [Scenario], roles: [String: AccountRole]) -> Bool {
        scenarios.contains { scenario in
            guard Self.needsLogin(scenario) else { return false }
            guard let roleKey = scenario.accountRoleKey else { return true }
            return roles[roleKey] == nil
        }
    }

    private static func needsLogin(_ scenario: Scenario) -> Bool {
        !scenario.account.contains("로그아웃 상태")
    }

    private static func parseHeader(_ lines: [String]) -> PlanHeader {
        var values: [String: String] = [:]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return PlanHeader(project: "", category: "", branch: "", commit: "", appVersion: "", dirty: false)
        }

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else {
                continue
            }
            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        let dirtyValue = values["dirty"]?
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespaces)

        return PlanHeader(
            project: values["project"] ?? "",
            category: values["category"] ?? "",
            branch: values["branch"] ?? "",
            commit: values["commit"] ?? "",
            appVersion: values["app_version"] ?? "",
            dirty: dirtyValue == "true"
        )
    }

    private static func parseCommonRunOptions(_ lines: [String]) -> [String: String] {
        guard let line = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("공통 실행 옵션:")
        }) else {
            return [:]
        }
        return optionValues(in: line)
    }

    private static func parseAccountEnvKeys(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: {
            matches(#"^##\s+3\.\s+준비\s*$"#, in: $0) != nil
        }) else {
            return []
        }

        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        guard let accountLine = lines[(start + 1)..<end].first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- 계정:")
        }) else {
            return []
        }

        return backtickValues(in: accountLine).filter {
            matches(#"^[A-Z][A-Z0-9_]+$"#, in: $0) != nil
        }
    }

    private static func parseScenarios(_ lines: [String]) -> [Scenario] {
        var scenarios: [Scenario] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            guard let heading = matches(
                #"^#{3,4} ([A-Z]{2,5}-\d{2}[a-z]?) · (.+)$"#,
                in: lines[lineIndex]
            ) else {
                lineIndex += 1
                continue
            }

            let blockEnd = lines[(lineIndex + 1)...].firstIndex(where: { $0.hasPrefix("#") }) ?? lines.endIndex
            let block = lines[(lineIndex + 1)..<blockEnd]
            var platform = ""
            var grade = Grade.C
            var gradeNote: String?
            var account = ""
            var accountRoleKey: String?
            var precondition: String?
            var goal = ""
            var passCondition: String?
            var evidence: String?
            var runOptionsNote: String?

            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let fields = matches(
                    // 계정 칸은 로그인하는 시나리오에만 있다.
                    #"^- platform:\s*(.*?)\s*·\s*등급:\s*([ABC])(?:\(([^)]*)\))?(?:\s*·\s*계정:\s*(.*))?$"#,
                    in: trimmed
                ) {
                    platform = fields[1]
                    grade = Grade(rawValue: fields[2]) ?? .C
                    gradeNote = fields[3].isEmpty ? nil : fields[3]
                    account = fields[4]
                    accountRoleKey = backtickValues(in: account).first {
                        matches(#"^[A-Za-z_][A-Za-z0-9_]*$"#, in: $0) != nil
                    }
                } else if trimmed.hasPrefix("- 사전 조건:") {
                    precondition = fieldValue(trimmed)
                } else if trimmed.hasPrefix("- goal:") {
                    goal = fieldValue(trimmed)
                } else if trimmed.hasPrefix("- 통과 조건:") {
                    passCondition = fieldValue(trimmed)
                } else if trimmed.hasPrefix("- 근거:") {
                    evidence = fieldValue(trimmed)
                } else if trimmed.hasPrefix("- 실행 옵션:") {
                    runOptionsNote = fieldValue(trimmed)
                }
            }

            scenarios.append(
                Scenario(
                    id: heading[1],
                    title: heading[2],
                    platform: platform,
                    grade: grade,
                    gradeNote: gradeNote,
                    account: account,
                    accountRoleKey: accountRoleKey,
                    precondition: precondition,
                    goal: goal,
                    passCondition: passCondition,
                    evidence: evidence,
                    runOptionsNote: runOptionsNote,
                    dependsOn: []
                )
            )
            lineIndex = blockEnd
        }

        return scenarios
    }

    private static func fieldValue(_ line: String) -> String {
        guard let separator = line.firstIndex(of: ":") else {
            return ""
        }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func optionValues(in text: String) -> [String: String] {
        var options: [String: String] = [:]
        for value in backtickValues(in: text) {
            guard let separator = value.firstIndex(of: "=") else {
                continue
            }
            let key = String(value[..<separator])
            options[key] = String(value[value.index(after: separator)...])
        }
        return options
    }

    private static func scenarioIDsIn(_ text: String) -> [String] {
        allMatches(#"[A-Z]{2,5}-\d{2}[a-z]?"#, in: text).map { $0[0] }
    }

    private static func backtickValues(in text: String) -> [String] {
        allMatches(#"`([^`]+)`"#, in: text).map { $0[1] }
    }

    private static func matches(_ pattern: String, in text: String) -> [String]? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let matchRange = match.range(at: index)
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: text)
                else {
                    return ""
                }
                return String(text[range])
            }
        }
    }
}

extension PlanDocument {
    public func updating(id: String, goal: String, passCondition: String?) throws -> PlanDocument {
        guard let scenarioIndex = scenarios.firstIndex(where: { $0.id == id }) else {
            throw NSError(
                domain: "QATwinCore.PlanDocument",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "시나리오를 찾을 수 없어요: \(id)"]
            )
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headingPrefixes = ["### \(id) · ", "#### \(id) · "]
        guard let headingIndex = lines.firstIndex(where: { line in
            headingPrefixes.contains(where: line.hasPrefix)
        }) else {
            throw NSError(
                domain: "QATwinCore.PlanDocument",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "시나리오 제목을 찾을 수 없어요: \(id)"]
            )
        }

        let blockEnd = lines[(headingIndex + 1)...].firstIndex(where: { $0.hasPrefix("#") }) ?? lines.endIndex
        guard let goalIndex = lines[(headingIndex + 1)..<blockEnd].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- goal:")
        }) else {
            throw NSError(
                domain: "QATwinCore.PlanDocument",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "goal 줄을 찾을 수 없어요: \(id)"]
            )
        }

        let flattenedGoal = Self.flattenedFieldValue(goal)
        lines[goalIndex] = Self.replacingFieldValue(in: lines[goalIndex], with: flattenedGoal)

        var updatedScenarios = scenarios
        updatedScenarios[scenarioIndex].goal = flattenedGoal
        if let passCondition {
            let flattenedPassCondition = Self.flattenedFieldValue(passCondition)
            if let passConditionIndex = lines[(headingIndex + 1)..<blockEnd].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- 통과 조건:")
            }) {
                lines[passConditionIndex] = Self.replacingFieldValue(
                    in: lines[passConditionIndex],
                    with: flattenedPassCondition
                )
            } else {
                lines.insert("- 통과 조건: \(flattenedPassCondition)", at: goalIndex + 1)
            }
            updatedScenarios[scenarioIndex].passCondition = flattenedPassCondition
        }

        return PlanDocument(
            url: url,
            text: lines.joined(separator: "\n"),
            header: header,
            scenarios: updatedScenarios,
            commonRunOptions: commonRunOptions,
            accountEnvKeys: accountEnvKeys
        )
    }

    public func write(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func flattenedFieldValue(_ value: String) -> String {
        value.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func replacingFieldValue(in line: String, with value: String) -> String {
        guard let separator = line.firstIndex(of: ":") else {
            return line
        }
        return String(line[...separator]) + " " + value
    }
}

public enum PlanSaveTarget {
    public static func resolve(plan: URL, hasRuns: Bool, now: Date) -> URL? {
        guard hasRuns else {
            return plan
        }

        let name = plan.lastPathComponent
        guard name.count > 11,
              let marker = name.range(of: "_test_plan", options: .backwards)
        else {
            return nil
        }

        let projectStart = name.index(name.startIndex, offsetBy: 11)
        guard projectStart < marker.lowerBound else {
            return nil
        }
        let project = String(name[projectStart..<marker.lowerBound])

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let plansDirectory = plan.deletingLastPathComponent()
        let baseTarget = plansDirectory.appending(
            path: "\(dateFormatter.string(from: now))-\(project)_test_plan.md"
        )
        guard FileManager.default.fileExists(atPath: baseTarget.path) else {
            return baseTarget
        }

        dateFormatter.dateFormat = "HHmm"
        let timedTarget = plansDirectory.appending(
            path: "\(baseTarget.deletingPathExtension().lastPathComponent)-\(dateFormatter.string(from: now)).md"
        )
        guard FileManager.default.fileExists(atPath: timedTarget.path) else {
            return timedTarget
        }
        return nil
    }
}
