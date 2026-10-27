import Foundation

public struct LoginPlan: Equatable, Sendable {
    public enum When: Equatable, Sendable {
        case none
        case duringPrepare
        case beforeScenario(String)
    }

    public let when: When
    public let role: String?

    public static func make(
        scenarios: [Scenario],
        roles: [String: AccountRole],
        chosenRole: String?
    ) -> LoginPlan {
        guard !roles.isEmpty,
              let index = scenarios.firstIndex(where: PlanDocument.needsLogin) else {
            return LoginPlan(when: .none, role: nil)
        }

        let scenario = scenarios[index]
        let when: When = index == scenarios.startIndex && !scenario.resetsAppData
            ? .duringPrepare
            : .beforeScenario(scenario.id)
        return LoginPlan(
            when: when,
            role: role(for: scenario, chosenRole: chosenRole, roles: roles)
        )
    }

    public static func defaultRole(
        scenarios: [Scenario],
        roles: [String: AccountRole]
    ) -> String? {
        guard !roles.isEmpty,
              let scenario = scenarios.first(where: PlanDocument.needsLogin) else {
            return nil
        }
        if let roleKey = scenario.accountRoleKey, roles[roleKey] != nil {
            return roleKey
        }
        return roles.keys.sorted().first
    }

    /// 그 시나리오 앞(초기화 뒤)에서 쓸 역할: 시나리오 역할 키 → chosenRole
    public static func role(
        for scenario: Scenario,
        chosenRole: String?,
        roles: [String: AccountRole]
    ) -> String? {
        if let roleKey = scenario.accountRoleKey, roles[roleKey] != nil {
            return roleKey
        }
        guard let chosenRole, roles[chosenRole] != nil else {
            return nil
        }
        return chosenRole
    }
}

public enum LoginOutcome: Equatable, Sendable {
    case loggedIn
    case alreadyLoggedIn
    case retryOnce(String)
    case failed(String)

    public static func interpret(
        status: Int32,
        output: String,
        freshInstallOrReset: Bool
    ) -> LoginOutcome {
        if status == 0 {
            return .loggedIn
        }
        if status == 7 {
            return freshInstallOrReset
                ? .failed("로그인 화면을 찾지 못했어요 — 권한 요청 창이나 온보딩이 가리고 있을 수 있어요")
                : .alreadyLoggedIn
        }

        let message = output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if status == 5 {
            let lowercased = output.lowercased()
            if output.contains("네트워크") || output.contains("연결") || lowercased.contains("network") {
                return .retryOnce(message)
            }
        }
        return .failed(message)
    }
}
