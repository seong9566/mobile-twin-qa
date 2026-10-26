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
