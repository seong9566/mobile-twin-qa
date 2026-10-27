import Foundation
import Testing
@testable import QATwinCore

@Suite struct ResetTests {
    @Test func parsesResetLine() throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try String(contentsOf: fixturePlan("2026-01-02-demo_app_test_plan.md"), encoding: .utf8)
        let text = original.replacingOccurrences(
            of: "- goal: 앱을 열어 첫 화면 인사 문구를 적어.",
            with: "- 초기화: 앱 데이터\n- goal: 앱을 열어 첫 화면 인사 문구를 적어."
        )
        let url = directory.appending(path: "2026-01-03-demo_app_test_plan.md")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let scenarios = try PlanDocument.load(url).scenarios

        #expect(scenarios.map(\.resetsAppData) == [true, false, false])
    }

    @Test func resetRunsClearGrantLaunchLoginBeforeRun() async throws {
        let (plan, scenario, directory) = try fixture(resets: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = api(for: [scenario])
        let shell = RecordingShell()

        let states = try await run(api: api, shell: shell, plan: plan, scenarios: [scenario], directory: directory, loginBefore: nil)

        let commands = shell.calls.map { ([$0.exe] + $0.args).joined(separator: " ") }
        #expect(commands.count >= 5)
        #expect(commands[0] == "/test/adb -s DEMO1 shell pm clear com.demo")
        #expect(commands[1] == "/test/adb -s DEMO1 shell pm grant com.demo android.permission.POST_NOTIFICATIONS")
        #expect(commands[2] == "/test/adb -s DEMO1 shell am start -n com.demo/.Main")
        #expect(commands[3].hasPrefix("/bin/bash /test/android-login.sh DEMO1 "))
        #expect(commands[3].hasSuffix("DEMO_USER_ID DEMO_USER_PASSWORD --tap 로그인 --wait 50"))
        #expect(await api.runs() == [scenario.id])
        #expect(states.contains(.preparing))
    }

    @Test func resetLoginFailureHoldsScenario() async throws {
        let (plan, scenario, directory) = try fixture(resets: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = api(for: [scenario])
        let shell = RecordingShell(responses: [("android-login.sh", 7, "로그인 화면이 아니다")])

        let states = try await run(api: api, shell: shell, plan: plan, scenarios: [scenario], directory: directory, loginBefore: nil)

        #expect(await api.runs().isEmpty)
        #expect(states.last == .held(reason: "초기화 실패: 로그인 화면을 찾지 못했어요 — 권한 요청 창이나 온보딩이 가리고 있을 수 있어요"))
    }

    @Test func loginBeforeWithoutResetSkipsClear() async throws {
        let (plan, scenario, directory) = try fixture(resets: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = api(for: [scenario])
        let shell = RecordingShell()

        _ = try await run(api: api, shell: shell, plan: plan, scenarios: [scenario], directory: directory, loginBefore: scenario.id)

        let commands = shell.calls.map { ([$0.exe] + $0.args).joined(separator: " ") }
        #expect(!commands.contains { $0.contains("pm clear") })
        #expect(commands.contains("/test/adb -s DEMO1 shell am start -n com.demo/.Main"))
        #expect(commands.contains { $0.contains("android-login.sh") })
        #expect(await api.runs() == [scenario.id])
    }

    @Test func runStateDecodesWithoutPrepare() throws {
        let json = """
        {"plan":"p.md","deviceSerial":"D","server":"dev","order":["A"],"states":{"A":{"waiting":{}}},
         "usage":{"llm_calls":0,"prompt_tokens":0,"completion_tokens":0}}
        """
        let state = try JSONDecoder().decode(RunStateFile.self, from: Data(json.utf8))

        #expect(state.prepare == nil)
        #expect(state.states["A"] == .waiting)
    }

    // MARK: 도구

    private func fixture(resets: Bool) throws -> (PlanDocument, Scenario, URL) {
        let plan = try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
        var scenario = plan.scenarios[0]
        scenario.resetsAppData = resets
        return (plan, scenario, try tempDir())
    }

    private func api(for scenarios: [Scenario]) -> FakeArtemisAPI {
        FakeArtemisAPI(
            goalIDs: Dictionary(uniqueKeysWithValues: scenarios.map { ($0.goal, $0.id) }),
            sessionIDs: Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, "S-\($0.id)") }),
            states: Dictionary(uniqueKeysWithValues: scenarios.map { ("S-\($0.id)", [SessionState.running, .completed]) }),
            usage: [:]
        )
    }

    /// 실행을 끝까지 돌리고 첫 시나리오가 거친 상태를 순서대로 돌려준다.
    private func run(
        api: FakeArtemisAPI,
        shell: RecordingShell,
        plan: PlanDocument,
        scenarios: [Scenario],
        directory: URL,
        loginBefore: String?
    ) async throws -> [ScenarioRunState] {
        let reset = ResetContext(
            package: "com.demo",
            launch: "com.demo/.Main",
            permissions: ["android.permission.POST_NOTIFICATIONS"],
            loginScript: URL(fileURLWithPath: "/test/android-login.sh"),
            envURL: directory.appending(path: ".env"),
            roles: ["user": AccountRole(idEnv: "DEMO_USER_ID", passwordEnv: "DEMO_USER_PASSWORD")],
            chosenRole: "user",
            loginBefore: loginBefore
        )
        let orchestrator = RunOrchestrator(
            api: api,
            shell: shell,
            runDir: directory,
            plan: plan,
            scenarios: scenarios,
            deviceSerial: "DEMO1",
            server: "local",
            planRelativePath: "personal/demo_app/plans/2026-01-02-demo_app_test_plan.md",
            artemisHome: directory,
            tracesDir: nil,
            adbPath: "/test/adb",
            pollInterval: .milliseconds(1),
            reset: reset
        )
        let id = scenarios[0].id
        let collector = Task {
            var states: [ScenarioRunState] = []
            for await event in orchestrator.events {
                if case .state(let eventID, let state) = event, eventID == id { states.append(state) }
                if event == .finished { break }
            }
            return states
        }
        await orchestrator.start()
        return await collector.value
    }
}
