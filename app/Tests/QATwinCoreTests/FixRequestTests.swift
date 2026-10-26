import Foundation
import Testing
@testable import QATwinCore

private func reviewTempDir() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinReviewTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func result(
    id: String,
    title: String? = nil,
    outcome: Outcome,
    cause: Cause?,
    rawCause: String? = nil,
    expected: String? = nil,
    actual: String? = nil,
    reason: String? = nil,
    evidence: [String] = []
) -> ScenarioResult {
    ScenarioResult(
        id: id,
        title: title,
        outcome: outcome,
        rawOutcome: nil,
        cause: cause,
        rawCause: rawCause,
        expected: expected,
        actual: actual,
        reason: reason,
        evidence: evidence
    )
}

private func runResults(_ scenarios: [ScenarioResult]) -> RunResults {
    RunResults(
        schemaVersion: 1,
        plan: "personal/demo_app/plans/2026-01-02-demo_app_test_plan.md",
        branch: "main",
        commit: "abc1234",
        appVersion: "1.0.0+1",
        device: "Pixel 9",
        server: "local",
        scenarios: scenarios
    )
}

@Test func defaultIncludeExcludesPassAndToolMisjudgment() {
    let review = Review()
    let pass = result(id: "HOME-01", outcome: .pass, cause: nil)
    let appDefect = result(id: "HOME-02", outcome: .fail, cause: .appDefect)
    let toolMisjudgment = result(id: "SET-01", outcome: .fail, cause: .toolMisjudgment)

    #expect(!review.entry(for: pass).include)
    #expect(review.entry(for: appDefect).include)
    #expect(!review.entry(for: toolMisjudgment).include)
}

@Test func rendersOnlyIncludedWithPlanFields() throws {
    let plan = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
    let results = runResults([
        result(
            id: "HOME-01",
            outcome: .fail,
            cause: .appDefect,
            expected: "안녕하세요 표시",
            actual: "문구 없음",
            evidence: ["artifacts/HOME-01/video.mp4"]
        ),
        result(id: "HOME-02", outcome: .fail, cause: .toolMisjudgment),
        result(id: "SET-01", outcome: .pass, cause: nil),
    ])
    let review = Review(entries: [
        "HOME-02": ReviewEntry(memo: "녹화 확인", causeOverride: nil, include: true),
    ])

    let markdown = FixRequestRenderer.render(
        results: results,
        plan: plan,
        review: review,
        project: "demo_app",
        runDirRelative: "personal/demo_app/runs/x/2026-01-03-0900"
    )

    #expect(markdown.contains("## HOME-01 · 첫 화면") && !markdown.contains("## SET-01"))
    #expect(markdown.contains("- 테스트 순서: \(plan.scenarios[0].goal)"))
    #expect(markdown.contains("도구의 오판일 수 있으니"))
    #expect(markdown.contains("`DEMO_USER_ID`"))
}

@Test func causeOverrideWins() {
    let results = runResults([
        result(id: "HOME-01", title: "첫 화면", outcome: .fail, cause: .appDefect),
    ])
    let review = Review(entries: [
        "HOME-01": ReviewEntry(memo: "", causeOverride: .environment, include: true),
    ])

    let markdown = FixRequestRenderer.render(
        results: results,
        plan: nil,
        review: review,
        project: "demo_app",
        runDirRelative: "personal/demo_app/runs/x/2026-01-03-0900"
    )

    #expect(markdown.contains("- 원인 구분: 환경"))
}

@Test func reviewRoundTrip() throws {
    let directory = try reviewTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let review = Review(entries: [
        "HOME-01": ReviewEntry(memo: "문구 수정", causeOverride: .appDefect, include: true),
    ])

    try review.save(runDir: directory)

    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "review.json").path))
    #expect(Review.load(runDir: directory).entries == review.entries)
}
