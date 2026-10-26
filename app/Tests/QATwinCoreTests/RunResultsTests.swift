import Foundation
import Testing
@testable import QATwinCore

private func fixtureRun(_ name: String) -> URL {
    fixtureRoot().appending(path: "personal/demo_app/runs/2026-01-02-demo_app_test_plan/\(name)")
}

@Test func loadsResultsJson() throws {
    let results = try RunResults.load(runDir: fixtureRun("2026-01-03-0900"))
    #expect(results.scenarios.first?.outcome == .fail && results.scenarios.first?.cause == .appDefect)
}

@Test func loadsUnknownOutcomeCauseAndMissingOptionalFields() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreRunResultsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
    {"schemaVersion":1,"plan":"personal/demo/plans/a.md","scenarios":[
      {"id":"HOME-01","outcome":"판정 보류","cause":"—"}
    ]}
    """
    try json.write(to: directory.appending(path: "results.json"), atomically: true, encoding: .utf8)

    let scenario = try #require(RunResults.load(runDir: directory).scenarios.first)
    #expect(scenario.outcome == nil && scenario.rawOutcome == "판정 보류")
    #expect(scenario.cause == nil && scenario.rawCause == "—")
    #expect(scenario.title == nil && scenario.expected == nil && scenario.evidence.isEmpty)
}

@Test func legacySummaryKeepsIrregularValues() throws {
    let results = try RunResults.load(runDir: fixtureRun("2026-01-02-1000"))
    let scenario = results.scenarios.first { $0.id == "SET-01" }!
    #expect(scenario.outcome == nil && scenario.rawOutcome == "통과 (키워드 단계 보류)")
    let toolFailure = results.scenarios.first { $0.id == "HOME-02" }!
    #expect(toolFailure.cause == nil && toolFailure.rawCause == "도구 이상")
    let appFailure = results.scenarios.first { $0.id == "HOME-01" }!
    #expect(appFailure.expected == "첫 화면 인사" && appFailure.actual == "빈 화면")
}

@Test func totalsSumTopLevelUsageOnly() throws {
    let directory = fixtureRun("2026-01-02-1000")
    let totals = RunTotals.compute(try RunResults.load(runDir: directory), runDir: directory)
    #expect(totals.llmCalls == 26 && totals.total == 3)
}

@Test func videoLookup() {
    #expect(Artifacts.video(runDir: fixtureRun("2026-01-02-1000"), id: "HOME-01") != nil)
}

@Test func checksSummaryCountsNonPassedAsFailed() {
    let summary = Artifacts.checksSummary(runDir: fixtureRun("2026-01-02-1000"), id: "HOME-01")
    #expect(summary?.passed == 1 && summary?.failed == 1)
}

@Test func checksSummaryKeepsLastCheckpointRecord() throws {
    let runDir = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreRunResultsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: runDir) }
    let artifacts = runDir.appending(path: "artifacts/HOME-01", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    let checks = #"{"records":[{"checkpoint_id":"CP-1","item_text":"첫 화면","status":"failed"},{"checkpoint_id":"CP-1","item_text":"첫 화면","status":"passed"}]}"#
    try checks.write(to: artifacts.appending(path: "checks.json"), atomically: true, encoding: .utf8)

    let summary = Artifacts.checksSummary(runDir: runDir, id: "HOME-01")
    #expect(summary?.passed == 1 && summary?.failed == 0)
}

@Test func loadsResultsJsonWithOnlyScenarios() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreRunResultsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"scenarios":[{"id":"HOME-01","outcome":"통과"}]}"#.write(
        to: directory.appending(path: "results.json"),
        atomically: true,
        encoding: .utf8
    )

    let results = try RunResults.load(runDir: directory)
    #expect(results.schemaVersion == 1 && results.plan.isEmpty)
    #expect(results.scenarios.map(\.id) == ["HOME-01"] && results.scenarios.first?.outcome == .pass)
}
