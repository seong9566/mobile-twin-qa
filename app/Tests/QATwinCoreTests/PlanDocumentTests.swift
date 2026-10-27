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
    #expect(plan.scenarios.map(\.accountRoleKey) == ["field_worker", "admin", nil, nil, "field_worker"])
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
    // "로그아웃 상태"가 아닌 "로그아웃"(로그아웃 기능을 쓰는 시나리오)은 로그인이 필요하다.
    #expect(keys(["ROLE-05"], roles) == ["TEST_USER_ID", "TEST_USER_PASSWORD"])
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

    #### ROLE-05 · 로그아웃 버튼
    - platform: android · 등급: A · 계정: 근무자 (`field_worker`, 로그아웃 후 다시 로그인)
    - goal: 설정에서 로그아웃을 눌러.
    """.write(to: url, atomically: true, encoding: .utf8)
    return try PlanDocument.load(url)
}

@Test func parsesGradeLineWithoutAccountField() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "QATwinPlanNoAccount-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "plan.md")
    try """
    ---
    source:
      branch: main
      commit: abc1234
      app_version: 1.0.0+1
    ---

    ## 4. 시나리오

    ### HOME-01 · 빈 홈

    - platform: android · 등급: A
    - goal: 앱을 연다.

    ### SCH-04 · 준비 전화

    - platform: android · 등급: B(사람이 시간 고르기)
    - goal: 일정을 만든다.
    """.write(to: url, atomically: true, encoding: .utf8)
    let plan = try PlanDocument.load(url)
    #expect(plan.scenarios.map(\.grade) == [.A, .B])
    // 계정 칸이 없으면 로그인하지 않으므로 계정 키를 요구하지 않는다.
    let roles = ["field_worker": AccountRole(idEnv: "WORKER_ID", passwordEnv: "WORKER_PASSWORD")]
    #expect(plan.requiredEnvKeys(for: plan.scenarios, roles: roles).isEmpty)
    #expect(!plan.usesAllAccountKeys(for: plan.scenarios, roles: roles))
    #expect(plan.scenarios.map(\.gradeNote) == [nil, "사람이 시간 고르기"])
    #expect(plan.scenarios.map(\.platform) == ["android", "android"])
}
