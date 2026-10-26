import Foundation
import Testing
@testable import QATwinCore

func fixturePlan(_ name: String) -> URL {
    fixtureRoot().appending(path: "personal/demo_app/plans/\(name)")
}

@Test func parsesHeaderAndH4Scenarios() throws {
    let document = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))

    #expect(document.header.commit == "abc1234" && document.header.appVersion == "1.0.0+1")
    #expect(document.scenarios.map(\.id) == ["HOME-01", "HOME-02", "SET-01"])
    #expect(document.scenarios[1].grade == .B && document.scenarios[1].gradeNote == "사람이 확인")
}

@Test func parsesH3TemplateHeadings() throws {
    #expect(
        try PlanDocument.load(fixturePlan("2026-01-01-demo_app_test_plan.md")).scenarios.map(\.id)
            == ["HOME-01"]
    )
}

@Test func dependsOnFromTitleAndPrecondition() throws {
    let scenarios = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md")).scenarios

    #expect(scenarios[1].dependsOn == ["HOME-01"])
    #expect(scenarios[2].dependsOn == ["HOME-02"])
}

@Test func envKeysAndRunOptions() throws {
    let document = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))

    #expect(document.accountEnvKeys == ["DEMO_USER_ID", "DEMO_USER_PASSWORD"])
    #expect(
        document.runOptions(for: document.scenarios[0])
            == [
                "profile": "pro",
                "locked_app_package": "com.demo",
                "verification_level": "checkpoints",
            ]
    )
    #expect(document.runOptions(for: document.scenarios[1])["locked_app_package"] == nil)
}
