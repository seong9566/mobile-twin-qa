import Foundation

public enum Grade: String, Codable {
    case A
    case B
    case C
}

public struct PlanHeader: Equatable {
    public var project: String
    public var category: String
    public var branch: String
    public var commit: String
    public var appVersion: String
    public var dirty: Bool
}

public struct Scenario: Identifiable, Hashable, Codable {
    public let id: String
    public var title: String
    public var platform: String
    public var grade: Grade
    public var gradeNote: String?
    public var account: String
    public var precondition: String?
    public var goal: String
    public var passCondition: String?
    public var evidence: String?
    public var runOptionsNote: String?
    public var dependsOn: [String]
}

public struct PlanDocument {
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
            var precondition: String?
            var goal = ""
            var passCondition: String?
            var evidence: String?
            var runOptionsNote: String?

            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let fields = matches(
                    #"^- platform:\s*(.*?)\s*·\s*등급:\s*([ABC])(?:\(([^)]*)\))?\s*·\s*계정:\s*(.*)$"#,
                    in: trimmed
                ) {
                    platform = fields[1]
                    grade = Grade(rawValue: fields[2]) ?? .C
                    gradeNote = fields[3].isEmpty ? nil : fields[3]
                    account = fields[4]
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
