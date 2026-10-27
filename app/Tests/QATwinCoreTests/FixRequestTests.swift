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

@Test func fillsEmptyMetadataAndIndentsMultilineMemo() throws {
    let plan = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
    var results = runResults([
        result(id: "HOME-01", outcome: .fail, cause: .appDefect),
    ])
    results.branch = ""
    results.commit = nil
    results.appVersion = " "
    results.device = ""
    results.server = nil
    let review = Review(entries: [
        "HOME-01": ReviewEntry(memo: "첫 줄\n둘째 줄", causeOverride: nil, include: true),
    ])

    let markdown = FixRequestRenderer.render(
        results: results,
        plan: plan,
        review: review,
        project: "demo_app",
        runDirRelative: "personal/demo_app/runs/x/2026-01-03-0900"
    )

    #expect(markdown.contains("- 소스: \(plan.header.branch) · \(plan.header.commit) · 앱 버전 \(plan.header.appVersion)"))
    #expect(markdown.contains("- 기기: 미확인 · 서버: 미확인"))
    #expect(markdown.contains("- 수정할 점: 첫 줄\n  둘째 줄"))
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

@Test func sectionMatchesWhatRenderWrites() throws {
    let plan = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
    let failed = result(id: "HOME-01", outcome: .fail, cause: .appDefect, expected: "안녕하세요 표시", actual: "문구 없음")
    let review = Review(entries: ["HOME-01": ReviewEntry(memo: "문구 키 확인", causeOverride: nil, include: true)])
    let section = FixRequestRenderer.section(
        result: failed, entry: review.entry(for: failed), plan: plan, runDirRelative: "personal/demo_app/runs/x/1"
    )
    let markdown = FixRequestRenderer.render(
        results: runResults([failed]), plan: plan, review: review, project: "demo_app",
        runDirRelative: "personal/demo_app/runs/x/1"
    )
    #expect(section.hasPrefix("## HOME-01 · "))
    #expect(section.hasSuffix("- 수정할 점: 문구 키 확인"))
    #expect(markdown.contains("\n" + section + "\n"))
}

@Test func renderWholeDocumentIsStable() {
    let failed = result(id: "HOME-01", outcome: .fail, cause: .appDefect, expected: "기대 문구", actual: "실제 문구")
    let misjudged = result(id: "HOME-02", outcome: .fail, cause: .appDefect)
    let review = Review(entries: ["HOME-02": ReviewEntry(memo: "", causeOverride: .toolMisjudgment, include: true)])
    let markdown = FixRequestRenderer.render(
        results: runResults([failed, misjudged]), plan: nil, review: review, project: "demo_app", runDirRelative: "r/1"
    )
    #expect(markdown == """
    # demo_app 수정 요청 — 1

    - 소스: main · abc1234 · 앱 버전 1.0.0+1
    - 기기: Pixel 9 · 서버: local
    - 실행 기록: `r/1/`

    ## HOME-01 · 

    - 원인 구분: 앱 결함
    - 기대: 기대 문구
    - 실제: 실제 문구

    ## HOME-02 · 

    - 원인 구분: 도구 오판

    ## 요청

    위 항목의 원인을 소스에서 찾아 수정안을 제시해 주세요. 계정·비밀값은 이 문서에 없습니다.
    원인 구분이 '도구 오판'인 항목은 테스트 도구의 오판일 수 있으니 코드를 고치기 전에 녹화로 먼저 확인해 주세요.

    """)
}
