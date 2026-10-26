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

@Test func accountRoleKeyFromAccountField() throws {
    let scenarios = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md")).scenarios

    #expect(scenarios.map(\.accountRoleKey) == ["user", "user", nil])
    let plan = try rolePlan()
    #expect(plan.scenarios.map(\.accountRoleKey) == ["field_worker", "admin", nil, nil])
}

@Test func requiredEnvKeysForSelectedScenarios() throws {
    let plan = try rolePlan()
    let roles = Workspace.accountRoles(projectYAML: """
    accounts:
      field_worker: { id_env: TEST_USER_ID, password_env: TEST_USER_PASSWORD }
      admin: { id_env: TEST_ADMIN_ID, password_env: TEST_ADMIN_PASSWORD }
    """)
    let byID = Dictionary(uniqueKeysWithValues: plan.scenarios.map { ($0.id, $0) })
    func keys(_ ids: [String], _ roles: [String: AccountRole]) -> [String] {
        plan.requiredEnvKeys(for: ids.compactMap { byID[$0] }, roles: roles)
    }

    // 역할 키가 모두 있으면 그 역할의 키만, 로그아웃 시나리오는 키가 필요 없다.
    #expect(keys(["ROLE-01"], roles) == ["TEST_USER_ID", "TEST_USER_PASSWORD"])
    #expect(
        keys(["ROLE-02", "ROLE-04", "ROLE-01", "ROLE-02"], roles)
            == ["TEST_ADMIN_ID", "TEST_ADMIN_PASSWORD", "TEST_USER_ID", "TEST_USER_PASSWORD"]
    )
    #expect(keys(["ROLE-04"], roles).isEmpty)
    #expect(!plan.usesAllAccountKeys(for: [byID["ROLE-01"]!, byID["ROLE-04"]!], roles: roles))
    // 하나라도 역할 키가 없으면 준비 절의 키 전체.
    #expect(keys(["ROLE-01", "ROLE-03"], roles) == plan.accountEnvKeys)
    #expect(plan.usesAllAccountKeys(for: [byID["ROLE-03"]!], roles: roles))
    // project.yaml에 없는 역할 키도 전체로 돌아간다.
    #expect(keys(["ROLE-01", "ROLE-02"], ["field_worker": roles["field_worker"]!]) == plan.accountEnvKeys)
}

private func rolePlan() throws -> PlanDocument {
    let url = FileManager.default.temporaryDirectory.appending(path: "role-plan-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try """
    ## 3. 준비

    - 계정: `TEST_USER_ID`·`TEST_USER_PASSWORD`·`TEST_ADMIN_ID`·`TEST_ADMIN_PASSWORD`·`OTHER_ID`

    ## 4. 시나리오

    #### ROLE-01 · 근무자
    - platform: android · 등급: A · 계정: 근무자 (`field_worker`)
    - goal: 홈을 열어.

    #### ROLE-02 · 관리자
    - platform: android · 등급: A · 계정: Master (`admin`, 근무 중)
    - goal: 관리 화면을 열어.

    #### ROLE-03 · 키 없음
    - platform: android · 등급: A · 계정: 근무자(근무 중)
    - goal: 홈을 열어.

    #### ROLE-04 · 로그아웃
    - platform: android · 등급: A · 계정: (로그아웃 상태)
    - goal: 로그인 화면을 열어.
    """.write(to: url, atomically: true, encoding: .utf8)
    return try PlanDocument.load(url)
}
