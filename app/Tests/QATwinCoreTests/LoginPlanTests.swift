import Testing
@testable import QATwinCore

@Suite struct LoginPlanTests {
    private let roles = [
        "user": AccountRole(idEnv: "USER_ID", passwordEnv: "USER_PASSWORD"),
    ]

    @Test func loginPlanFirstScenarioLogsInDuringPrepare() {
        let plan = LoginPlan.make(
            scenarios: [scenario(id: "A", account: "사용자 (`user`)", roleKey: "user")],
            roles: roles,
            chosenRole: nil
        )

        #expect(plan == LoginPlan(when: .duringPrepare, role: "user"))
    }

    @Test func loginPlanSkipsPrepareWhenFirstLoginResets() {
        let plan = LoginPlan.make(
            scenarios: [
                scenario(id: "A", account: "사용자 (`user`)", roleKey: "user", resetsAppData: true),
            ],
            roles: roles,
            chosenRole: nil
        )

        #expect(plan == LoginPlan(when: .beforeScenario("A"), role: "user"))
    }

    @Test func loginPlanWaitsForFirstLoginScenario() {
        let plan = LoginPlan.make(
            scenarios: [
                scenario(id: "L", account: "로그아웃 상태"),
                scenario(id: "A", account: "사용자 (`user`)", roleKey: "user"),
            ],
            roles: roles,
            chosenRole: nil
        )

        #expect(plan == LoginPlan(when: .beforeScenario("A"), role: "user"))
    }

    @Test func loginPlanNone() {
        #expect(
            LoginPlan.make(
                scenarios: [scenario(id: "A")],
                roles: roles,
                chosenRole: "user"
            ) == LoginPlan(when: .none, role: nil)
        )
        #expect(
            LoginPlan.make(
                scenarios: [scenario(id: "A", account: "사용자")],
                roles: [:],
                chosenRole: nil
            ) == LoginPlan(when: .none, role: nil)
        )
    }

    @Test func defaultRoleFallsBack() {
        let loginScenario = scenario(id: "A", account: "사용자")
        let oneRole = [
            "user": AccountRole(idEnv: "USER_ID", passwordEnv: "USER_PASSWORD"),
        ]
        let manyRoles = [
            "worker": AccountRole(idEnv: "WORKER_ID", passwordEnv: "WORKER_PASSWORD"),
            "admin": AccountRole(idEnv: "ADMIN_ID", passwordEnv: "ADMIN_PASSWORD"),
        ]

        #expect(LoginPlan.defaultRole(scenarios: [loginScenario], roles: oneRole) == "user")
        #expect(LoginPlan.defaultRole(scenarios: [loginScenario], roles: manyRoles) == "admin")
    }

    @Test func loginOutcomeInterpretsCodes() {
        #expect(LoginOutcome.interpret(status: 0, output: "", freshInstallOrReset: true) == .loggedIn)
        #expect(
            LoginOutcome.interpret(status: 7, output: "", freshInstallOrReset: false)
                == .alreadyLoggedIn
        )
        #expect(
            LoginOutcome.interpret(status: 7, output: "", freshInstallOrReset: true)
                == .failed("로그인 화면을 찾지 못했어요 — 권한 요청 창이나 온보딩이 가리고 있을 수 있어요")
        )
        #expect(
            LoginOutcome.interpret(status: 5, output: "다시 시도\n네트워크 오류\n", freshInstallOrReset: false)
                == .retryOnce("네트워크 오류")
        )
        #expect(
            LoginOutcome.interpret(status: 5, output: "NETWORK unavailable", freshInstallOrReset: false)
                == .retryOnce("NETWORK unavailable")
        )
        #expect(
            LoginOutcome.interpret(status: 4, output: "\n포커스 실패\n", freshInstallOrReset: false)
                == .failed("포커스 실패")
        )
    }

    private func scenario(
        id: String,
        account: String = "",
        roleKey: String? = nil,
        resetsAppData: Bool = false
    ) -> Scenario {
        Scenario(
            id: id,
            title: id,
            platform: "android",
            grade: .A,
            account: account,
            accountRoleKey: roleKey,
            resetsAppData: resetsAppData,
            goal: "테스트해요",
            dependsOn: []
        )
    }
}
