import Foundation
import Testing
@testable import QATwinCore

@Suite struct PrepareCoordinatorTests {
    @Test func prepareStartsArtemisAndServerWhenDown() async throws {
        let fixture = try makeFixture(server: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = FakeArtemisAPI(deviceResponses: [.failure(.unreachable), .success([])])
        let health = FakeHealth(responses: [false, true])
        let launcher = FakeLauncher(scripts: [
            ("artemis ui", "sleep 30"),
            ("server-start", "sleep 30"),
        ])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: api,
            shell: readyShell(),
            health: health,
            launcher: launcher,
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(events.contains { event in
            if case .item(.artemis, .done) = event { return true }
            return false
        })
        #expect(events.contains { event in
            if case .item(.server, .done) = event { return true }
            return false
        })
        let result = try #require(finishedResult(events))
        #expect(result.artemisStartedByApp)
        #expect(result.serverStartedByApp)
        #expect(launcher.calls.contains { call in
            call.args.joined(separator: " ").contains("export ARTEMIS_HOME=")
                && call.args.joined(separator: " ").contains("uv run artemis ui --port 8100")
        })
        for process in await coordinator.ownedProcesses() {
            await process.terminate()
        }
    }

    @Test func prepareSkipsBuildAndInstallWhenRecordMatches() async throws {
        let fixture = try makeFixture(build: "build-app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let buildEnv = BuildEnv.make(
            envURL: fixture.projectDir.appending(path: ".env"),
            accountKeys: [],
            server: fixture.input.config.servers["local"]!,
            macIP: "127.0.0.1"
        )
        try InstallRecords.save(
            InstallEntry(
                package: "com.example.demo",
                commit: "source123",
                dirty: false,
                envSHA256: buildEnv.sha256,
                at: Date()
            ),
            serial: "DEVICE1",
            projectDir: fixture.projectDir
        )
        let shell = readyShell()
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: shell,
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(events.contains { event in
            if case .item(.build, .skipped) = event { return true }
            return false
        })
        #expect(shell.calls.contains { $0.args.contains("am") && $0.args.contains("start") })
        #expect(!shell.calls.contains { $0.args.contains("install") && $0.args.contains("-r") })
    }

    @Test func prepareFailsFastWhenServerExits() async throws {
        let fixture = try makeFixture(server: true, serverTimeout: 30)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launcher = FakeLauncher(scripts: [
            ("server-start", "echo 'address already in use'; exit 1"),
        ])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: readyShell(),
            health: FakeHealth(responses: [false]),
            launcher: launcher,
            pollInterval: .milliseconds(10)
        )
        let started = ContinuousClock.now

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(events.contains { event in
            if case let .item(.server, .failed(reason)) = event {
                return reason.contains("address already in use")
            }
            return false
        })
    }

    @Test func prepareWaitsForUnlockThenContinues() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = readyShell(windowResponses: [
            "mDreamingLockscreen=true",
            "mDreamingLockscreen=true",
            "mDreamingLockscreen=false",
        ])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: shell,
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        let waitingIndex = events.firstIndex { event in
            if case .item(.device, .waitingForHuman) = event { return true }
            return false
        }
        let doneIndex = events.firstIndex { event in
            if case .item(.device, .done) = event { return true }
            return false
        }
        #expect(waitingIndex != nil)
        #expect(doneIndex != nil)
        #expect(waitingIndex! < doneIndex!)
        #expect(finishedResult(events)?.succeeded == true)
    }

    @Test func prepareRejectsTrackedFileChange() async throws {
        let fixture = try makeFixture(build: "build-app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = readyShell(extra: [
            ("status --porcelain", 0, ""),
            ("status --porcelain", 0, " M tracked.txt\n"),
        ])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: shell,
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(scripts: [("build-app", "exit 0")]),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(events.contains(
            .item(.build, .failed("빌드가 원본 repo의 추적 파일을 바꿨어요 — 되돌리지 않았어요"))
        ))
        #expect(finishedResult(events)?.succeeded == false)
    }

    @Test func prepareFailsWhenMacIPIsNeededButMissing() async throws {
        let fixture = try makeFixture(build: "build-app", vars: #"vars: { API_BASE_URL: "http://{{mac_ip}}:5199" }"#)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: readyShell(),
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(scripts: [("build-app", "exit 0")]),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(events.contains(.item(.build, .failed("맥의 IP 주소를 찾지 못했어요 — 맥의 네트워크 연결을 확인해 주세요"))))
    }

    @Test func prepareChecksDiffInSourceDir() async throws {
        let fixture = try makeFixture(build: "build-app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = readyShell()
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: shell,
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(scripts: [("build-app", "exit 0")]),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        _ = await collected

        let commands = shell.calls.map { ([$0.exe] + $0.args).joined(separator: " ") }
        #expect(commands.contains("/usr/bin/git -C \(fixture.input.sourceDir.path) diff"))
        #expect(!commands.contains { $0.contains("shasum") })
    }

    @Test func prepareFailureTextIsRedacted() async throws {
        let fixture = try makeFixture(login: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: readyShell(extra: [("android-login.sh", 5, "비밀번호 top-secret 이(가) 틀렸어요")]),
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(),
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        await coordinator.run()
        let events = await collected

        #expect(events.contains(.item(.login, .failed("비밀번호 **** 이(가) 틀렸어요"))))
        #expect(finishedResult(events)?.failure == "비밀번호 **** 이(가) 틀렸어요")
        #expect(!String(describing: events).contains("top-secret"))
    }

    @Test func prepareLogRedactsSecrets() async throws {
        let fixture = try makeFixture(login: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = readyShell(extra: [
            ("android-login.sh", 0, "token=top-secret API_BASE_URL=http://127.0.0.1:5199"),
        ])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: shell,
            health: FakeHealth(responses: []),
            launcher: FakeLauncher(),
            pollInterval: .milliseconds(10)
        )

        await coordinator.run()
        let contents = try String(contentsOf: fixture.input.logURL, encoding: .utf8)

        #expect(contents.contains("****"))
        #expect(!contents.contains("top-secret"))
        #expect(contents.contains("API_BASE_URL=http://127.0.0.1:5199"))
    }

    @Test func cancelStopsChildAndCreatesNoRunDir() async throws {
        let fixture = try makeFixture(build: "long-build")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launcher = FakeLauncher(scripts: [("long-build", "sleep 30")])
        let coordinator = PrepareCoordinator(
            input: fixture.input,
            api: FakeArtemisAPI(),
            shell: readyShell(),
            health: FakeHealth(responses: []),
            launcher: launcher,
            pollInterval: .milliseconds(10)
        )

        async let collected = collect(coordinator.events)
        let runTask = Task { await coordinator.run() }
        try await waitUntil { launcher.calls.contains { $0.args.joined(separator: " ").contains("long-build") } }
        await coordinator.cancel()
        await runTask.value
        let events = await collected

        #expect(launcher.processes.allSatisfy { !$0.isRunning })
        #expect(!FileManager.default.fileExists(atPath: fixture.projectDir.appending(path: "runs").path))
        #expect(finishedResult(events)?.succeeded == false)
        #expect(finishedResult(events)?.failure == "사용자 취소")
    }
}

private final class FakeHealth: HealthChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Bool]

    init(responses: [Bool]) {
        self.responses = responses
    }

    func isUp(_ url: URL) async -> Bool {
        lock.withLock {
            guard let response = responses.first else { return false }
            if responses.count > 1 {
                responses.removeFirst()
            }
            return response
        }
    }
}

private final class FakeLauncher: ProcessLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [(match: String, script: String)]
    private(set) var calls: [(exe: String, args: [String], cwd: URL, logURL: URL?)] = []
    private(set) var processes: [ManagedProcess] = []

    init(scripts: [(match: String, script: String)] = []) {
        self.scripts = scripts
    }

    func launch(exe: String, args: [String], cwd: URL, logURL: URL?) throws -> ManagedProcess {
        let command = ([exe] + args).joined(separator: " ")
        let script = lock.withLock {
            calls.append((exe, args, cwd, logURL))
            return scripts.first(where: { command.contains($0.match) })?.script ?? "exit 0"
        }
        let process = ManagedProcess(exe: "/bin/sh", args: ["-c", script], cwd: cwd, logURL: nil)
        try process.start()
        lock.withLock {
            processes.append(process)
        }
        return process
    }
}

private struct PrepareFixture {
    let root: URL
    let projectDir: URL
    let input: PrepareInput
}

private func makeFixture(
    server: Bool = false,
    serverTimeout: Int = 1,
    build: String? = nil,
    login: Bool = false,
    vars: String = "vars: {}"
) throws -> PrepareFixture {
    let root = try tempDir("PrepareCoordinatorTests")
    let projectDir = root.appending(path: "personal/demo")
    let sourceDir = root.appending(path: "source")
    let artemisHome = root.appending(path: "artemis")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: artemisHome, withIntermediateDirectories: true)
    let projectYAML = login
        ? "accounts:\n  user: { id_env: USER_ID, password_env: USER_PASSWORD }\n"
        : "accounts: {}\n"
    try projectYAML.write(
        to: projectDir.appending(path: "project.yaml"),
        atomically: true,
        encoding: .utf8
    )
    try "USER_ID=user@example.com\nUSER_PASSWORD=top-secret\nAPI_BASE_URL=http://127.0.0.1:5199\n"
        .write(to: projectDir.appending(path: ".env"), atomically: true, encoding: .utf8)
    let planText = """
    ---
    project: demo
    category: personal
    branch: main
    commit: plan123
    app_version: 1.0
    dirty: false
    ---

    ### HOME-01 · 홈
    - platform: android · 등급: A\(login ? " · 계정: 사용자 (`user`)" : "")
    - goal: 홈을 확인해요
    """
    let planURL = projectDir.appending(path: "plan.md")
    try planText.write(to: planURL, atomically: true, encoding: .utf8)
    let plan = try PlanDocument.load(planURL)
    let serverBlock = server
        ? "health: http://127.0.0.1:5199/health\n    start: server-start\n    start_timeout: \(serverTimeout)"
        : vars
    let buildBlock = build.map { "\nbuild:\n  android: \($0)\n  android_apk: build/app.apk" } ?? ""
    let config = ProjectConfig.parse("""
    apps:
      android:
        package: com.example.demo
        launch: com.example.demo/.MainActivity
    environments:
      default: local
      local:
        \(serverBlock)
    \(buildBlock)
    """)
    let input = PrepareInput(
        projectDir: projectDir,
        sourceDir: sourceDir,
        config: config,
        serverName: "local",
        serial: "DEVICE1",
        scenarios: plan.scenarios,
        plan: plan,
        loginRole: login ? "user" : nil,
        forceRebuild: false,
        artemisURL: URL(string: "http://127.0.0.1:8100")!,
        artemisHome: artemisHome,
        tracesDir: nil,
        adbPath: "/test/adb",
        loginScript: URL(fileURLWithPath: "/tools/android-login.sh"),
        logURL: root.appending(path: "prepare.log")
    )
    return PrepareFixture(root: root, projectDir: projectDir, input: input)
}

private func readyShell(
    windowResponses: [String] = ["mDreamingLockscreen=false"],
    extra: [(match: String, status: Int32, out: String)] = []
) -> RecordingShell {
    RecordingShell(responses: extra + [
        ("rev-parse HEAD", 0, "source123\n"),
        ("status --porcelain", 0, ""),
        (" diff", 0, "same diff\n"),
        ("get-state", 0, "device\n"),
    ] + windowResponses.map { ("dumpsys window", 0, $0) } + [
        ("cmd wifi status", 0, "Wifi is enabled\nWifi is connected"),
        ("zen_mode", 0, "0\n"),
        ("pm path", 0, "package:/data/app/demo.apk\n"),
        ("POST_NOTIFICATION", 0, "POST_NOTIFICATION: allow\n"),
    ])
}

private func collect(_ stream: AsyncStream<PrepareEvent>) async -> [PrepareEvent] {
    var events: [PrepareEvent] = []
    for await event in stream {
        events.append(event)
        if case .finished = event {
            break
        }
    }
    return events
}

private func finishedResult(_ events: [PrepareEvent]) -> PrepareResult? {
    for event in events.reversed() {
        if case let .finished(result) = event {
            return result
        }
    }
    return nil
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
