import Foundation
import Testing
@testable import QATwinCore

private func tempDir() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func date(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: value)!
}

@Test func updatingReplacesOnlyThatScenario() throws {
    let document = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
    let edited = try document.updating(id: "HOME-01", goal: "새 순서", passCondition: "새 조건")

    #expect(edited.scenarios[0].goal == "새 순서" && edited.scenarios[0].passCondition == "새 조건")
    #expect(
        edited.text.replacingOccurrences(of: "새 순서", with: document.scenarios[0].goal)
            .replacingOccurrences(of: "새 조건", with: document.scenarios[0].passCondition!) == document.text
    )
}

@Test func multilineGoalIsFlattened() throws {
    let edited = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
        .updating(id: "HOME-01", goal: "가\n나", passCondition: nil)

    #expect(edited.scenarios[0].goal == "가 나")
}

@Test func saveTargetRules() throws {
    let directory = tempDir()
    let plan = directory.appending(path: "2026-01-02-demo_app_test_plan.md")
    try "x".write(to: plan, atomically: true, encoding: .utf8)
    let now = date("2026-01-02 15:30")

    #expect(PlanSaveTarget.resolve(plan: plan, hasRuns: false, now: now) == plan)
    #expect(
        PlanSaveTarget.resolve(plan: plan, hasRuns: true, now: now)?.lastPathComponent
            == "2026-01-02-demo_app_test_plan-1530.md"
    )
}

@Test func safetyLint() {
    #expect(!SafetyLint.warnings(goal: "비상 연락처에 전화를 걸어 확인해").isEmpty)
    #expect(SafetyLint.warnings(goal: "전화 확인 시트가 뜨면 '전화'는 누르지 마").isEmpty)
}
