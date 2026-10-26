import Foundation

public enum Outcome: String, Codable {
    case pass = "통과"
    case fail = "실패"
    case hold = "보류"
    case notRun = "미실행"
}

public enum Cause: String, Codable, CaseIterable {
    case appDefect = "앱 결함"
    case toolMisjudgment = "도구 오판"
    case environment = "환경"
}

public struct ScenarioResult: Codable, Identifiable, Equatable {
    public let id: String
    public var title: String?
    public var outcome: Outcome?
    public var rawOutcome: String?
    public var cause: Cause?
    public var rawCause: String?
    public var expected: String?
    public var actual: String?
    public var reason: String?
    public var evidence: [String]
}

public struct RunResults: Codable {
    public var schemaVersion: Int
    public var plan: String
    public var branch: String?
    public var commit: String?
    public var appVersion: String?
    public var device: String?
    public var server: String?
    public var scenarios: [ScenarioResult]

    public static func load(runDir: URL) throws -> RunResults {
        let resultsURL = runDir.appending(path: "results.json")
        if FileManager.default.fileExists(atPath: resultsURL.path) {
            return try JSONDecoder().decode(RunResults.self, from: Data(contentsOf: resultsURL))
        }

        return try loadLegacySummary(runDir: runDir)
    }

    private static func loadLegacySummary(runDir: URL) throws -> RunResults {
        let summary = try String(contentsOf: runDir.appending(path: "summary.md"), encoding: .utf8)
        let lines = summary.components(separatedBy: .newlines)
        var device: String?
        var server: String?
        var commit: String?
        var scenarios: [ScenarioResult] = []
        var inTable = false

        for line in lines {
            if let header = captures(
                #"^- 기기:\s*(.*?)\s*·\s*서버:\s*(.*?)\s*·\s*소스:\s*(.*?)(?:\s*·|$)"#,
                in: line
            ) {
                device = header[1]
                server = header[2]
                commit = header[3]
            }

            if line.trimmingCharacters(in: .whitespaces) == "| ID | 결과 | 판정 | 근거 | 비용 |" {
                inTable = true
                continue
            }
            guard inTable else {
                continue
            }
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else {
                inTable = false
                continue
            }

            let columns = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst()
                .dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 5, columns[0] != "---" else {
                continue
            }

            let outcome = Outcome(rawValue: columns[1])
            let cause = Cause(rawValue: columns[2])
            scenarios.append(
                ScenarioResult(
                    id: columns[0],
                    title: nil,
                    outcome: outcome,
                    rawOutcome: outcome == nil ? columns[1] : nil,
                    cause: cause,
                    rawCause: cause == nil && columns[2] != "—" ? columns[2] : nil,
                    expected: nil,
                    actual: nil,
                    reason: nil,
                    evidence: capturesAll(#"`(artifacts/[^`]+)`"#, in: columns[3])
                )
            )
        }

        for line in lines {
            guard let detail = captures(#"^- \*\*([^*]+)\*\*\s+—\s+(.*)$"#, in: line),
                  let index = scenarios.firstIndex(where: { $0.id == detail[1] })
            else {
                continue
            }

            if let values = captures(
                #"기대(?:\([^)]*\))?\s*:\s*(.*?)\.\s*실제\s*:\s*(.*?)(?:\.\s.*|\.$|$)"#,
                in: detail[2]
            ) {
                scenarios[index].expected = values[1]
                scenarios[index].actual = values[2]
            } else {
                scenarios[index].reason = line
            }
        }

        let planDirectory = runDir.deletingLastPathComponent()
        let projectDirectory = planDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let category = projectDirectory.deletingLastPathComponent().lastPathComponent
        let plan = "\(category)/\(projectDirectory.lastPathComponent)/plans/\(planDirectory.lastPathComponent).md"

        return RunResults(
            schemaVersion: 0,
            plan: plan,
            branch: nil,
            commit: commit,
            appVersion: nil,
            device: device,
            server: server,
            scenarios: scenarios
        )
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              )
        else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return ""
            }
            return String(text[range])
        }
    }

    private static func capturesAll(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
    }
}

public struct RunTotals: Equatable {
    public var pass: Int
    public var fail: Int
    public var hold: Int
    public var notRun: Int
    public var total: Int
    public var llmCalls: Int
    public var promptTokens: Int
    public var completionTokens: Int

    public static func compute(_ results: RunResults, runDir: URL) -> RunTotals {
        var totals = RunTotals(
            pass: 0,
            fail: 0,
            hold: 0,
            notRun: 0,
            total: results.scenarios.count,
            llmCalls: 0,
            promptTokens: 0,
            completionTokens: 0
        )

        for scenario in results.scenarios {
            switch scenario.outcome {
            case .pass:
                totals.pass += 1
            case .fail:
                totals.fail += 1
            case .hold:
                totals.hold += 1
            case .notRun:
                totals.notRun += 1
            case nil:
                break
            }

            let usageURL = runDir
                .appending(path: "artifacts")
                .appending(path: scenario.id)
                .appending(path: "usage.json")
            guard let data = try? Data(contentsOf: usageURL),
                  let usage = try? JSONDecoder().decode(Usage.self, from: data)
            else {
                continue
            }
            totals.llmCalls += usage.llmCalls
            totals.promptTokens += usage.promptTokens
            totals.completionTokens += usage.completionTokens
        }

        return totals
    }

    private struct Usage: Decodable {
        let llmCalls: Int
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case llmCalls = "llm_calls"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

public enum Artifacts {
    public static func video(runDir: URL, id: String) -> URL? {
        let url = runDir.appending(path: "artifacts").appending(path: id).appending(path: "video.mp4")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return nil
        }
        return url
    }

    public static func checksSummary(runDir: URL, id: String) -> (passed: Int, failed: Int)? {
        let url = runDir.appending(path: "artifacts").appending(path: id).appending(path: "checks.json")
        guard let data = try? Data(contentsOf: url),
              let checks = try? JSONDecoder().decode(Checks.self, from: data)
        else {
            return nil
        }

        let passed = checks.records.count { $0.status == "passed" }
        return (passed: passed, failed: checks.records.count - passed)
    }

    private struct Checks: Decodable {
        let records: [Record]
    }

    private struct Record: Decodable {
        let status: String
    }
}
