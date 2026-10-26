import Foundation
import Testing
@testable import QATwinCore

private final class FakeArtemisAPI: ArtemisAPI, @unchecked Sendable {
    private let goalIDs: [String: String]
    private let lock = NSLock()
    private let runErrors: [String: ArtemisError]
    private let sessionIDs: [String: String]
    private var stateResponses: [String: [SessionState]]
    private var stateFailures: [String: Int]
    private let usageResponses: [String: Usage]
    private var runCalls: [String] = []
    private var saveCalls: [(sessionID: String, path: String)] = []
    private let saveDelay: Duration?
    private var stopCalls: [String] = []

    init(
        goalIDs: [String: String],
        sessionIDs: [String: String],
        states: [String: [SessionState]],
        usage: [String: Usage] = [:],
        runErrors: [String: ArtemisError] = [:],
        stateFailures: [String: Int] = [:],
        saveDelay: Duration? = nil
    ) {
        self.goalIDs = goalIDs
        self.stateFailures = stateFailures
        self.runErrors = runErrors
        self.saveDelay = saveDelay
        self.sessionIDs = sessionIDs
        self.stateResponses = states
        self.usageResponses = usage
    }

    func devices() async throws -> [ArtemisDevice] {
        []
    }

    func run(
        goal: String,
        options: [String: String],
        deviceSerial: String
    ) async throws -> String {
        try withLock {
            let id = goalIDs[goal] ?? goal
            runCalls.append(id)
            if let error = runErrors[id] {
                throw error
            }
            return sessionIDs[id] ?? "S\(runCalls.count)"
        }
    }

    func state(_ sid: String) async throws -> SessionState {
        try withLock {
            if let remaining = stateFailures[sid], remaining > 0 {
                stateFailures[sid] = remaining - 1
                throw ArtemisError.unreachable
            }
            guard var responses = stateResponses[sid], let response = responses.first else {
                return .completed
            }
            if responses.count > 1 {
                responses.removeFirst()
                stateResponses[sid] = responses
            }
            return response
        }
    }

    func usage(_ sid: String) async throws -> Usage {
        usageResponses[sid] ?? Usage(llm_calls: 0, prompt_tokens: 0, completion_tokens: 0)
    }

    func stop(_ sid: String) async throws {
        withLock {
            stopCalls.append(sid)
        }
    }

    func saveArtifacts(_ sid: String, to dir: URL) async throws -> Bool {
        let result = withLock {
            saveCalls.append((sid, dir.path))
            return true
        }
        if let saveDelay {
            try await Task.sleep(for: saveDelay)
        }
        return result
    }

    func runs() async -> [String] {
        withLock { runCalls }
    }

    func saves() async -> [(sessionID: String, path: String)] {
        withLock { saveCalls }
    }

    func stops() async -> [String] {
        withLock { stopCalls }
    }

    private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor FakeShellRunner: ShellRunner {
    private var calls: [(exe: String, args: [String])] = []
    private let output: String

    init(output: String = "Wifi is enabled\nWifi is connected to \"demo\"") {
        self.output = output
    }

    func run(_ exe: String, _ args: [String], timeout: Duration) async throws -> (status: Int32, out: String) {
        calls.append((exe, args))
        return (0, output)
    }

    func recordedCalls() -> [(exe: String, args: [String])] {
        calls
    }
}

private func orchestratorTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreRunOrchestratorTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixtureDocument() throws -> PlanDocument {
    try PlanDocument.load(fixturePlan("2026-01-02-demo_app_test_plan.md"))
}

private func goalIDs(_ scenarios: [Scenario]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: scenarios.map { ($0.goal, $0.id) })
}

private func makeOrchestrator(
    api: FakeArtemisAPI,
    shell: FakeShellRunner = FakeShellRunner(),
    runDir: URL,
    plan: PlanDocument,
    scenarios: [Scenario],
    artemisHome: URL,
    adbPath: String? = "/test/adb"
) -> RunOrchestrator {
    RunOrchestrator(
        api: api,
        shell: shell,
        runDir: runDir,
        plan: plan,
        scenarios: scenarios,
        deviceSerial: "DEMO1",
        server: "local",
        planRelativePath: "personal/demo_app/plans/2026-01-02-demo_app_test_plan.md",
        artemisHome: artemisHome,
        tracesDir: nil,
        adbPath: adbPath,
        pollInterval: .milliseconds(1)
    )
}

private func collectUntilFinished(_ stream: AsyncStream<RunEvent>) async -> [RunEvent] {
    var events: [RunEvent] = []
    for await event in stream {
        events.append(event)
        if event == .finished {
            break
        }
    }
    return events
}

private func readRunState(_ runDir: URL) throws -> RunStateFile {
    try JSONDecoder().decode(
        RunStateFile.self,
        from: Data(contentsOf: runDir.appending(path: "run-state.json"))
    )
}

@Test func runsInOrderAndSavesArtifacts() async throws {
    let plan = try fixtureDocument()
    let scenarios = plan.scenarios
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1", "HOME-02": "S2", "SET-01": "S3"],
        states: [
            "S1": [.running, .completed],
            "S2": [.running, .completed],
            "S3": [.running, .completed],
        ],
        usage: [
            "S1": Usage(llm_calls: 1, prompt_tokens: 10, completion_tokens: 1),
            "S2": Usage(llm_calls: 2, prompt_tokens: 20, completion_tokens: 2),
            "S3": Usage(llm_calls: 3, prompt_tokens: 30, completion_tokens: 3),
        ]
    )
    let shell = FakeShellRunner()
    let orchestrator = makeOrchestrator(
        api: api,
        shell: shell,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    _ = await events.value

    #expect(await api.runs() == ["HOME-01", "HOME-02", "SET-01"])
    let saves = await api.saves()
    #expect(saves.map(\.sessionID) == ["S1", "S2", "S3"])
    #expect(saves[0].path.hasSuffix("/artifacts/HOME-01"))
    let shellCalls = await shell.recordedCalls()
    #expect(shellCalls.first?.exe == "/test/adb")
    #expect(shellCalls.first?.args == ["-s", "DEMO1", "shell", "cmd", "wifi", "status"])
    let state = try readRunState(directory)
    #expect(state.plan == "personal/demo_app/plans/2026-01-02-demo_app_test_plan.md")
    #expect(state.states["HOME-01"] == .finished(sessionID: "S1", artemis: "completed"))
    #expect(state.usage == Usage(llm_calls: 6, prompt_tokens: 60, completion_tokens: 6))
}

@Test func dependentHeldWhenPrereqNotCompleted() async throws {
    let plan = try fixtureDocument()
    let scenarios = Array(plan.scenarios.prefix(2))
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1", "HOME-02": "S2"],
        states: ["S1": [.failed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )

    await orchestrator.start()

    #expect(await api.runs() == ["HOME-01"])
    let state = try readRunState(directory)
    #expect(state.states["HOME-02"] == .held(reason: "사전 조건 HOME-01 미완료"))
}

@Test func lockedPhoneHeldAndContinues() async throws {
    let plan = try fixtureDocument()
    var first = plan.scenarios[0]
    var last = plan.scenarios[2]
    first.dependsOn = []
    last.dependsOn = []
    let scenarios = [first, last]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["SET-01": "S2"],
        states: ["S2": [.completed]],
        runErrors: ["HOME-01": .deviceLocked]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )

    await orchestrator.start()

    #expect(await api.runs() == ["HOME-01", "SET-01"])
    let state = try readRunState(directory)
    #expect(state.states["HOME-01"] == .held(reason: "폰 잠김(409)"))
    #expect(state.states["SET-01"] == .finished(sessionID: "S2", artemis: "completed"))
}

@Test func spendLimitInLogStopsAndMarksRest() async throws {
    let plan = try fixtureDocument()
    let scenarios = plan.scenarios
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StallDetector.traceLog(sessionID: "S1", artemisHome: directory, tracesDir: nil)
    try FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "enforced_spend_limit_reached".write(to: log, atomically: true, encoding: .utf8)
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.running]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(await api.stops() == ["S1"])
    let state = try readRunState(directory)
    #expect(state.states["HOME-01"] == .held(reason: "API 지출 한도"))
    #expect(state.states["HOME-02"] == .notRun(reason: "API 지출 한도"))
    #expect(state.states["SET-01"] == .notRun(reason: "API 지출 한도"))
    #expect(received.contains(.spendLimitReached))
}

@Test func stallWarnsOnceAndDoesNotStop() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StallDetector.traceLog(sessionID: "S1", artemisHome: directory, tracesDir: nil)
    try FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "running".write(to: log, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-301)],
        ofItemAtPath: log.path
    )
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.running, .completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    let stalls = received.filter { event in
        if case .stall = event {
            return true
        }
        return false
    }
    #expect(stalls.count == 1)
    #expect(await api.stops().isEmpty)
}

@Test func stopAllMarksRemainingNotRun() async throws {
    let plan = try fixtureDocument()
    let scenarios = Array(plan.scenarios.prefix(2))
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.running]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let run = Task { await orchestrator.start() }

    while await api.runs().isEmpty {
        try await Task.sleep(for: .milliseconds(1))
    }
    await orchestrator.stopAll()
    await run.value

    #expect(await api.stops() == ["S1"])
    let state = try readRunState(directory)
    #expect(state.states["HOME-01"] == .held(reason: "사용자 중지"))
    #expect(state.states["HOME-02"] == .notRun(reason: "사용자 중지"))
}

@Test func retryMovesToTry1Once() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts = directory.appending(path: "artifacts/HOME-01", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try "old".write(
        to: artifacts.appending(path: "checks.json"),
        atomically: true,
        encoding: .utf8
    )
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )

    await orchestrator.retry(id: "HOME-01")
    await orchestrator.retry(id: "HOME-01")

    #expect(await api.runs() == ["HOME-01"])
    #expect(
        FileManager.default.fileExists(
            atPath: artifacts.appending(path: "try1/checks.json").path
        )
    )
}

@Test func bGradeEmitsHumanAction() async throws {
    let plan = try fixtureDocument()
    var scenario = plan.scenarios[1]
    scenario.dependsOn = []
    let scenarios = [scenario]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-02": "S1"],
        states: ["S1": [.completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(
        received.contains(.humanAction(id: "HOME-02", note: "사람이 확인"))
    )
}

@Test func wifiDownWarnsOncePerScenario() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.running, .running, .running, .completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        shell: FakeShellRunner(output: "Wifi is enabled\nWifi is not connected"),
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(received.filter { $0 == .wifiDown(id: "HOME-01") }.count == 1)
}

@Test func transientPollFailureIsTolerated() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.completed]],
        stateFailures: ["S1": 2]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    _ = await events.value

    #expect(try readRunState(directory).states["HOME-01"] == .finished(sessionID: "S1", artemis: "completed"))
    #expect(await api.stops().isEmpty)
}

@Test func repeatedPollFailureWarnsAndContinues() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.completed]],
        stateFailures: ["S1": 3]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(try readRunState(directory).states["HOME-01"] == .finished(sessionID: "S1", artemis: "completed"))
    #expect(received.filter { $0 == .pollFailing(id: "HOME-01", reason: "Artemis 응답 없음") }.count == 1)
    #expect(await api.stops().isEmpty)
}

@Test func stopRequestedDuringArtifactSaveDoesNotHoldNextScenario() async throws {
    let plan = try fixtureDocument()
    var first = plan.scenarios[0]
    var second = plan.scenarios[2]
    first.dependsOn = []
    second.dependsOn = []
    let scenarios = [first, second]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1", "SET-01": "S2"],
        states: ["S1": [.completed], "S2": [.completed]],
        saveDelay: .milliseconds(20)
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let run = Task { await orchestrator.start() }

    while await api.saves().isEmpty {
        try await Task.sleep(for: .milliseconds(1))
    }
    await orchestrator.stopCurrentAsHeld()
    await run.value

    #expect(await api.runs() == ["HOME-01", "SET-01"])
    #expect(try readRunState(directory).states["SET-01"] == .finished(sessionID: "S2", artemis: "completed"))
}

@Test func retryEarlyReturnStillFinishesStream() async throws {
    let plan = try fixtureDocument()
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(goalIDs: [:], sessionIDs: [:], states: [:])
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: [plan.scenarios[0]],
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.retry(id: "UNKNOWN-99")

    #expect(await events.value == [.finished])
}

@Test func rearmStallRestartsFrozenLogTimer() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StallDetector.traceLog(sessionID: "S1", artemisHome: directory, tracesDir: nil)
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "running".write(to: log, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-301)],
        ofItemAtPath: log.path
    )
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": Array(repeating: .running, count: 8) + [.completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task {
        var received: [RunEvent] = []
        for await event in orchestrator.events {
            received.append(event)
            if case .stall(let id, _) = event {
                await orchestrator.rearmStall(id: id)
            }
            if event == .finished { break }
        }
        return received
    }

    await orchestrator.start()
    let received = await events.value

    #expect(received.filter { if case .stall = $0 { true } else { false } }.count == 1)
}

@Test func missingTraceLogWarnsOnceAfterSixRunningPolls() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": Array(repeating: .running, count: 7) + [.completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(received.filter { $0 == .traceLogMissing(id: "HOME-01") }.count == 1)
}

@Test func missingADBWarnsAndSkipsWifiCommand() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": [.running, .completed]]
    )
    let shell = FakeShellRunner()
    let orchestrator = makeOrchestrator(
        api: api,
        shell: shell,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory,
        adbPath: nil
    )
    let events = Task { await collectUntilFinished(orchestrator.events) }

    await orchestrator.start()
    let received = await events.value

    #expect(received.filter { $0 == .adbUnavailable(id: "HOME-01") }.count == 1)
    #expect(await shell.recordedCalls().isEmpty)
}

@Test func rearmStallIgnoresIdleLoopBeforeKeepWaiting() async throws {
    let plan = try fixtureDocument()
    let scenarios = [plan.scenarios[0]]
    let directory = try orchestratorTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StallDetector.traceLog(sessionID: "S1", artemisHome: directory, tracesDir: nil)
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let idle = "Generated summary for Step 3\n" + String(repeating: "LLM stopped without calling any tool\n", count: 12)
    try idle.write(to: log, atomically: true, encoding: .utf8)
    let api = FakeArtemisAPI(
        goalIDs: goalIDs(scenarios),
        sessionIDs: ["HOME-01": "S1"],
        states: ["S1": Array(repeating: .running, count: 8) + [.completed]]
    )
    let orchestrator = makeOrchestrator(
        api: api,
        runDir: directory,
        plan: plan,
        scenarios: scenarios,
        artemisHome: directory
    )
    let events = Task {
        var received: [RunEvent] = []
        for await event in orchestrator.events {
            received.append(event)
            if case .stall(let id, _) = event {
                await orchestrator.rearmStall(id: id)
            }
            if event == .finished { break }
        }
        return received
    }

    await orchestrator.start()
    let received = await events.value

    #expect(received.filter { if case .stall = $0 { true } else { false } }.count == 1)
}
