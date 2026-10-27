import Foundation

public protocol HealthChecker: Sendable {
    func isUp(_ url: URL) async -> Bool
}

public struct URLSessionHealthChecker: HealthChecker {
    public init() {}

    public func isUp(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }
}

public protocol ProcessLauncher: Sendable {
    func launch(exe: String, args: [String], cwd: URL, logURL: URL?) throws -> ManagedProcess
}

public struct DefaultProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(exe: String, args: [String], cwd: URL, logURL: URL?) throws -> ManagedProcess {
        let process = ManagedProcess(exe: exe, args: args, cwd: cwd, logURL: logURL)
        try process.start()
        return process
    }
}

public enum PrepareStep: String, CaseIterable, Sendable {
    case artemis
    case server
    case device
    case build
    case install
    case login
    case scenarios
}

public enum PrepareItemState: Equatable, Sendable {
    case waiting
    case running
    case done(String)
    case skipped(String)
    case waitingForHuman(String)
    case failed(String)
}

public enum PrepareEvent: Equatable, Sendable {
    case item(PrepareStep, PrepareItemState)
    case log(String)
    case finished(PrepareResult)
}

public struct PrepareResult: Codable, Equatable, Sendable {
    public var artemisStartedByApp: Bool
    public var serverStartedByApp: Bool
    public var buildSkipped: Bool
    public var skipReason: String?
    public var installedCommit: String?
    public var sourceCommit: String?
    public var planCommit: String
    public var loginRole: String?
    public var durationSeconds: Int
    public var succeeded: Bool
    public var failure: String?

    public init(
        artemisStartedByApp: Bool,
        serverStartedByApp: Bool,
        buildSkipped: Bool,
        skipReason: String?,
        installedCommit: String?,
        sourceCommit: String?,
        planCommit: String,
        loginRole: String?,
        durationSeconds: Int,
        succeeded: Bool,
        failure: String?
    ) {
        self.artemisStartedByApp = artemisStartedByApp
        self.serverStartedByApp = serverStartedByApp
        self.buildSkipped = buildSkipped
        self.skipReason = skipReason
        self.installedCommit = installedCommit
        self.sourceCommit = sourceCommit
        self.planCommit = planCommit
        self.loginRole = loginRole
        self.durationSeconds = durationSeconds
        self.succeeded = succeeded
        self.failure = failure
    }
}

public struct PrepareInput: Sendable {
    public let projectDir: URL
    public let sourceDir: URL
    public let config: ProjectConfig
    public let serverName: String
    public let serial: String
    public let scenarios: [Scenario]
    public let plan: PlanDocument
    public let loginRole: String?
    public let forceRebuild: Bool
    public let artemisURL: URL
    public let artemisHome: URL
    public let tracesDir: URL?
    public let adbPath: String
    public let loginScript: URL
    public let logURL: URL

    public init(
        projectDir: URL,
        sourceDir: URL,
        config: ProjectConfig,
        serverName: String,
        serial: String,
        scenarios: [Scenario],
        plan: PlanDocument,
        loginRole: String?,
        forceRebuild: Bool,
        artemisURL: URL,
        artemisHome: URL,
        tracesDir: URL?,
        adbPath: String,
        loginScript: URL,
        logURL: URL
    ) {
        self.projectDir = projectDir
        self.sourceDir = sourceDir
        self.config = config
        self.serverName = serverName
        self.serial = serial
        self.scenarios = scenarios
        self.plan = plan
        self.loginRole = loginRole
        self.forceRebuild = forceRebuild
        self.artemisURL = artemisURL
        self.artemisHome = artemisHome
        self.tracesDir = tracesDir
        self.adbPath = adbPath
        self.loginScript = loginScript
        self.logURL = logURL
    }
}

public actor PrepareCoordinator {
    private let api: ArtemisAPI
    private let clock: any Clock<Duration>
    private let continuation: AsyncStream<PrepareEvent>.Continuation
    private let eventStream: AsyncStream<PrepareEvent>
    private let health: HealthChecker
    private let input: PrepareInput
    private let launcher: ProcessLauncher
    private let log: PrepareLog
    private let pollInterval: Duration
    private let shell: ShellRunner

    private var activeProcess: ManagedProcess?
    private var artemisProcess: ManagedProcess?
    private var cachedMacIP: String?
    private var sourceDirty = false
    private var cancelled = false
    private var deviceStatus: DeviceStatus?
    private var failedStep: PrepareStep?
    private var finishedForAttempt = false
    private var isRunning = false
    private var result: PrepareResult
    private var serverProcess: ManagedProcess?
    private var sleepTask: Task<Void, Never>?
    private var startedAt = Date()

    public init(
        input: PrepareInput,
        api: ArtemisAPI,
        shell: ShellRunner,
        health: HealthChecker,
        launcher: ProcessLauncher,
        clock: any Clock<Duration> = ContinuousClock(),
        pollInterval: Duration = .seconds(5)
    ) {
        let events = AsyncStream<PrepareEvent>.makeStream()
        let secrets = Self.secretValues(input: input)
        self.api = api
        self.clock = clock
        self.continuation = events.continuation
        self.eventStream = events.stream
        self.health = health
        self.input = input
        self.launcher = launcher
        self.log = PrepareLog(url: input.logURL, secrets: secrets)
        self.pollInterval = pollInterval
        self.shell = shell
        self.result = PrepareResult(
            artemisStartedByApp: false,
            serverStartedByApp: false,
            buildSkipped: false,
            skipReason: nil,
            installedCommit: nil,
            sourceCommit: nil,
            planCommit: input.plan.header.commit,
            loginRole: input.loginRole,
            durationSeconds: 0,
            succeeded: false,
            failure: nil
        )
    }

    public nonisolated var events: AsyncStream<PrepareEvent> {
        eventStream
    }

    public func run() async {
        guard !isRunning else { return }
        resetAttempt()
        await run(from: .artemis)
    }

    public func retryFromFailed() async {
        guard !isRunning, let failedStep else { return }
        resetAttempt()
        await run(from: failedStep)
    }

    public func cancel() async {
        cancelled = true
        sleepTask?.cancel()
        if let activeProcess {
            await activeProcess.terminate()
            self.activeProcess = nil
        }
        finish(succeeded: false, failure: "사용자 취소")
    }

    public func recheckDevice() async {
        sleepTask?.cancel()
    }

    public func ownedProcesses() -> [ManagedProcess] {
        [artemisProcess, serverProcess].compactMap { $0 }
    }

    public static func preflight(
        input: PrepareInput,
        api: ArtemisAPI,
        shell: ShellRunner,
        health: HealthChecker,
        launcher: ProcessLauncher
    ) async -> (items: [PrepareStep: PrepareItemState], artemis: ManagedProcess?) {
        var items: [PrepareStep: PrepareItemState] = Dictionary(
            uniqueKeysWithValues: PrepareStep.allCases.map { ($0, PrepareItemState.waiting) }
        )
        var artemis: ManagedProcess?

        do {
            _ = try await api.devices()
            items[.artemis] = .done("응답해요")
        } catch {
            if isLoopback(input.artemisURL) {
                do {
                    artemis = try launchArtemis(input: input, launcher: launcher)
                    let deadline = Date().addingTimeInterval(60)
                    while Date() < deadline {
                        if (try? await api.devices()) != nil {
                            items[.artemis] = .done("꺼져 있어서 띄웠어요 · 응답해요")
                            break
                        }
                        if let artemis, !artemis.isRunning {
                            let reason = artemisFailure(process: artemis, port: input.artemisURL.port ?? 8100)
                            items[.artemis] = .failed(reason)
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if case .waiting = items[.artemis] {
                        await artemis?.terminate()
                        items[.artemis] = .failed("Artemis 서버가 60초 안에 응답하지 않았어요")
                    }
                } catch {
                    items[.artemis] = .failed(error.localizedDescription)
                }
            } else {
                items[.artemis] = .waitingForHuman("다른 기기의 Artemis라 띄울 수 없어요")
            }
        }

        let server = input.config.servers[input.serverName]
        if let healthText = server?.health,
           let healthURL = URL(string: replacingMacIP(healthText, with: "127.0.0.1")) {
            if await health.isUp(healthURL) {
                items[.server] = .done("응답해요")
            } else if server?.start != nil {
                items[.server] = .waitingForHuman("시작하면 띄워요")
            } else {
                items[.server] = .waitingForHuman("서버가 응답하지 않아요, 직접 띄워 주세요")
            }
        } else {
            items[.server] = .skipped("health 설정이 없어요")
        }

        let status = await DeviceProbe(shell: shell, adbPath: input.adbPath)
            .status(serial: input.serial, package: input.config.package)
        items[.device] = status.blockers.isEmpty
            ? .done(status.warnings.joined(separator: " · "))
            : .waitingForHuman(status.blockers.joined(separator: " · "))
        items[.build] = .waiting
        items[.install] = .waiting

        let roles = roles(input: input)
        let loginPlan = LoginPlan.make(
            scenarios: input.scenarios,
            roles: roles,
            chosenRole: input.loginRole
        )
        switch loginPlan.when {
        case .none:
            items[.login] = .skipped("로그인하는 시나리오가 없어요")
        case let .beforeScenario(id):
            items[.login] = .skipped("\(id) 초기화 뒤에 해요")
        case .duringPrepare:
            items[.login] = .waiting
        }
        return (items, artemis)
    }

    private func resetAttempt() {
        cancelled = false
        finishedForAttempt = false
        isRunning = true
        startedAt = Date()
        result.succeeded = false
        result.failure = nil
    }

    private func run(from firstStep: PrepareStep) async {
        let steps = PrepareStep.allCases
        let startIndex = steps.firstIndex(of: firstStep) ?? 0
        do {
            for step in steps[startIndex...] {
                try checkCancellation()
                switch step {
                case .artemis: try await prepareArtemis()
                case .server: try await prepareServer()
                case .device: try await prepareDevice()
                case .build: try await prepareBuild()
                case .install: try await prepareInstall()
                case .login: try await prepareLogin()
                case .scenarios: completeScenarios()
                }
            }
            failedStep = nil
            finish(succeeded: true, failure: nil)
        } catch let failure as PrepareFailure {
            if !cancelled {
                failedStep = failure.step
                emit(.item(failure.step, .failed(failure.message)))
                appendLog(failure.step, failure.message)
                finish(succeeded: false, failure: failure.message)
            }
        } catch {
            if !cancelled {
                let step = failedStep ?? firstStep
                let message = error.localizedDescription
                failedStep = step
                emit(.item(step, .failed(message)))
                appendLog(step, message)
                finish(succeeded: false, failure: message)
            }
        }
        activeProcess = nil
        isRunning = false
    }

    private func prepareArtemis() async throws {
        emit(.item(.artemis, .running))
        if (try? await api.devices()) != nil {
            emit(.item(.artemis, .done("응답해요")))
            return
        }
        guard Self.isLoopback(input.artemisURL) else {
            throw PrepareFailure(.artemis, "다른 기기의 Artemis라 띄울 수 없어요")
        }

        if artemisProcess?.isRunning != true {
            do {
                let process = try Self.launchArtemis(input: input, launcher: launcher)
                artemisProcess = process
                activeProcess = process
                result.artemisStartedByApp = true
                appendLog(.artemis, "uv run artemis ui --port \(input.artemisURL.port ?? 8100)")
            } catch {
                throw PrepareFailure(.artemis, error.localizedDescription)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try checkCancellation()
            if (try? await api.devices()) != nil {
                activeProcess = nil
                emit(.item(.artemis, .done("꺼져 있어서 띄웠어요 · 응답해요")))
                return
            }
            if let process = artemisProcess, !process.isRunning {
                throw PrepareFailure(
                    .artemis,
                    Self.artemisFailure(process: process, port: input.artemisURL.port ?? 8100)
                )
            }
            await sleepForPoll()
        }
        await artemisProcess?.terminate()
        throw PrepareFailure(.artemis, "Artemis 서버가 60초 안에 응답하지 않았어요")
    }

    private func prepareServer() async throws {
        guard let server = input.config.servers[input.serverName], let healthText = server.health else {
            emit(.item(.server, .skipped("health 설정이 없어요")))
            return
        }
        guard let healthURL = URL(string: Self.replacingMacIP(healthText, with: await macIP() ?? "127.0.0.1")) else {
            throw PrepareFailure(.server, "서버 health 주소가 올바르지 않아요")
        }
        emit(.item(.server, .running))
        if await health.isUp(healthURL) {
            emit(.item(.server, .done("응답해요")))
            return
        }
        guard let command = server.start else {
            throw PrepareFailure(.server, "서버가 응답하지 않아요, 직접 띄워 주세요")
        }

        if serverProcess?.isRunning != true {
            let arguments = LoginShell.arguments(command, exports: [])
            do {
                let process = try launcher.launch(
                    exe: arguments.exe,
                    args: arguments.args,
                    cwd: input.sourceDir.appending(path: server.cwd),
                    logURL: nil
                )
                serverProcess = process
                activeProcess = process
                result.serverStartedByApp = true
                appendLog(.server, command)
            } catch {
                throw PrepareFailure(.server, error.localizedDescription)
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(server.startTimeout))
        while Date() < deadline {
            try checkCancellation()
            if await health.isUp(healthURL) {
                if let output = serverProcess?.tail(lines: 30), !output.isEmpty {
                    appendLog(.server, output)
                }
                activeProcess = nil
                emit(.item(.server, .done("띄웠어요 · 응답해요")))
                return
            }
            if let process = serverProcess, !process.isRunning {
                let output = process.tail(lines: 30).trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrepareFailure(.server, output.isEmpty ? "테스트 서버가 먼저 종료됐어요" : output)
            }
            await sleepForPoll()
        }
        await serverProcess?.terminate()
        serverProcess = nil
        throw PrepareFailure(.server, "테스트 서버가 \(server.startTimeout)초 안에 응답하지 않았어요")
    }

    private func prepareDevice() async throws {
        emit(.item(.device, .running))
        let probe = DeviceProbe(shell: shell, adbPath: input.adbPath)
        while true {
            try checkCancellation()
            let status = await probe.status(serial: input.serial, package: input.config.package)
            deviceStatus = status
            if status.blockers.isEmpty {
                let detail = status.warnings.isEmpty ? "사용할 수 있어요" : status.warnings.joined(separator: " · ")
                emit(.item(.device, .done(detail)))
                return
            }
            let reason = status.blockers.joined(separator: " · ")
            emit(.item(.device, .waitingForHuman(reason)))
            appendLog(.device, reason)
            await sleepForPoll()
        }
    }

    private func prepareBuild() async throws {
        emit(.item(.build, .running))
        let sourceCommit = try await gitOutput(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.sourceCommit = sourceCommit.isEmpty ? nil : sourceCommit

        guard let buildCommand = input.config.buildAndroid else {
            result.buildSkipped = true
            result.skipReason = "빌드 명령이 없어요"
            emit(.item(.build, .skipped("빌드 명령이 없어요")))
            return
        }

        // 소스 dirty는 계획 머리말이 아니라 지금 소스의 git 상태로 본다.
        let sourceDirty = !(try await gitOutput(["status", "--porcelain"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.sourceDirty = sourceDirty
        let env = try await makeBuildEnv()
        let record = InstallRecords.load(projectDir: input.projectDir)[input.serial]
        let decision = BuildSkip.decide(
            entry: record,
            headCommit: sourceCommit,
            sourceDirty: sourceDirty,
            envSHA256: env.sha256,
            packageInstalled: deviceStatus?.packageInstalled == true,
            forceRebuild: input.forceRebuild
        )
        if decision == .skip {
            result.buildSkipped = true
            result.skipReason = "설치본이 최신이에요"
            result.installedCommit = record?.commit
            emit(.item(.build, .skipped("설치본이 최신이에요")))
            return
        }
        if case let .build(reason) = decision {
            result.skipReason = reason
            appendLog(.build, reason)
        }

        let before = try await gitSnapshot()
        var envURL: URL?
        defer {
            if let envURL {
                try? FileManager.default.removeItem(at: envURL)
            }
        }
        if input.config.usesQAAppEnv {
            envURL = try env.write(to: input.logURL.deletingLastPathComponent())
        }
        let exports = envURL.map { [("QA_APP_ENV", $0.path)] } ?? []
        let arguments = LoginShell.arguments(buildCommand, exports: exports)
        appendLog(.build, LoginShell.command(buildCommand, exports: exports))
        let process: ManagedProcess
        do {
            process = try launcher.launch(
                exe: arguments.exe,
                args: arguments.args,
                cwd: input.sourceDir,
                logURL: nil
            )
        } catch {
            throw PrepareFailure(.build, error.localizedDescription)
        }
        activeProcess = process
        let output = try await waitForProcess(process, step: .build, timeout: 20 * 60)
        appendLog(.build, output)
        activeProcess = nil
        guard process.exitStatus == 0 else {
            throw PrepareFailure(.build, lastMessage(output, fallback: "빌드에 실패했어요"))
        }

        let after = try await gitSnapshot()
        guard before == after else {
            throw PrepareFailure(.build, "빌드가 원본 repo의 추적 파일을 바꿨어요 — 되돌리지 않았어요")
        }
        emit(.item(.build, .done("빌드했어요")))
    }

    private func prepareInstall() async throws {
        emit(.item(.install, .running))
        if !result.buildSkipped, let apk = input.config.androidAPK {
            let apkURL = input.sourceDir.appending(path: apk)
            let installed = try await runShell(
                step: .install,
                exe: input.adbPath,
                args: ["-s", input.serial, "install", "-r", apkURL.path],
                timeout: .seconds(180)
            )
            guard installed.status == 0 else {
                throw PrepareFailure(.install, lastMessage(installed.out, fallback: "앱 설치에 실패했어요"))
            }
            try await grantPermissions()
            if let package = input.config.package, let commit = result.sourceCommit {
                let env = try await makeBuildEnv()
                try InstallRecords.save(
                    InstallEntry(
                        package: package,
                        commit: commit,
                        dirty: sourceDirty,
                        envSHA256: env.sha256,
                        at: Date()
                    ),
                    serial: input.serial,
                    projectDir: input.projectDir
                )
                result.installedCommit = commit
            }
        } else if result.buildSkipped {
            emit(.item(.install, .skipped("설치본을 그대로 써요")))
        }

        if let launch = input.config.launch {
            let launched = try await runShell(
                step: .install,
                exe: input.adbPath,
                args: ["-s", input.serial, "shell", "am", "start", "-n", launch],
                timeout: .seconds(20)
            )
            guard launched.status == 0 else {
                throw PrepareFailure(.install, lastMessage(launched.out, fallback: "앱을 실행하지 못했어요"))
            }
        }
        if !result.buildSkipped {
            emit(.item(.install, .done("설치하고 실행했어요")))
        }
    }

    private func prepareLogin() async throws {
        let roles = Self.roles(input: input)
        let plan = LoginPlan.make(
            scenarios: input.scenarios,
            roles: roles,
            chosenRole: input.loginRole
        )
        switch plan.when {
        case .none:
            emit(.item(.login, .skipped("로그인하는 시나리오가 없어요")))
        case let .beforeScenario(id):
            emit(.item(.login, .skipped("\(id) 초기화 뒤에 해요")))
        case .duringPrepare:
            emit(.item(.login, .running))
            guard let roleKey = plan.role, let role = roles[roleKey] else {
                throw PrepareFailure(.login, "로그인 역할을 찾지 못했어요")
            }
            result.loginRole = roleKey
            let freshInstall = !result.buildSkipped
            var outcome = try await login(role: role, freshInstall: freshInstall)
            if case .retryOnce = outcome {
                outcome = try await login(role: role, freshInstall: freshInstall)
            }
            switch outcome {
            case .loggedIn:
                emit(.item(.login, .done("로그인했어요")))
            case .alreadyLoggedIn:
                emit(.item(.login, .done("이미 로그인돼 있어요")))
            case let .retryOnce(message), let .failed(message):
                throw PrepareFailure(.login, message.isEmpty ? "로그인에 실패했어요" : message)
            }
        }
    }

    private func completeScenarios() {
        emit(.item(.scenarios, .done("\(input.scenarios.count)개 시나리오를 준비했어요")))
    }

    private func login(role: AccountRole, freshInstall: Bool) async throws -> LoginOutcome {
        let envURL = input.projectDir.appending(path: ".env")
        let command = [
            "bash",
            shellQuote(input.loginScript.path),
            shellQuote(input.serial),
            shellQuote(envURL.path),
            shellQuote(role.idEnv),
            shellQuote(role.passwordEnv),
            "--tap",
            shellQuote("로그인"),
            "--wait",
            "50",
        ].joined(separator: " ")
        // GUI 앱의 PATH에는 adb가 없다. adb 폴더를 PATH 앞에 둔다.
        let arguments = LoginShell.arguments(
            "export PATH=\"$QA_ADB_DIR:$PATH\"; " + command,
            exports: [("QA_ADB_DIR", URL(fileURLWithPath: input.adbPath).deletingLastPathComponent().path)]
        )
        let response = try await runShell(
            step: .login,
            exe: arguments.exe,
            args: arguments.args,
            timeout: .seconds(120)
        )
        return LoginOutcome.interpret(
            status: response.status,
            output: response.out,
            freshInstallOrReset: freshInstall
        )
    }

    private func grantPermissions() async throws {
        let started = Date()
        for permission in input.config.permissions {
            let remaining = 30 - Date().timeIntervalSince(started)
            guard remaining > 0 else {
                throw PrepareFailure(.install, "권한 부여가 30초 안에 끝나지 않았어요")
            }
            let response = try await runShell(
                step: .install,
                exe: input.adbPath,
                args: [
                    "-s", input.serial, "shell", "pm", "grant",
                    input.config.package ?? "", permission,
                ],
                timeout: .seconds(remaining)
            )
            if response.status != 0 {
                appendLog(.install, "권한 \(permission) 부여 실패: \(response.out)")
            }
        }
    }

    /// 빌드 env를 만든다. 서버 vars가 `{{mac_ip}}`를 쓰는데 맥 IP를 못 찾으면 실패한다(127.0.0.1을 APK에 굽지 않는다).
    private func makeBuildEnv() async throws -> BuildEnv {
        let server = input.config.servers[input.serverName]
            ?? ServerConfig(name: input.serverName, health: nil, start: nil, cwd: ".", startTimeout: 60, vars: [:])
        let address = await macIP()
        let envText = (try? String(contentsOf: input.projectDir.appending(path: ".env"), encoding: .utf8)) ?? ""
        let needsIP = server.vars.values.contains { $0.contains("{{mac_ip}}") } || envText.contains("{{mac_ip}}")
        if address == nil, needsIP {
            throw PrepareFailure(.build, "맥의 IP 주소를 찾지 못했어요 — 맥의 네트워크 연결을 확인해 주세요")
        }
        let projectYAML = (try? String(
            contentsOf: input.projectDir.appending(path: "project.yaml"),
            encoding: .utf8
        )) ?? ""
        return BuildEnv.make(
            envURL: input.projectDir.appending(path: ".env"),
            accountKeys: Set(Workspace.accountEnvKeys(projectYAML: projectYAML)),
            server: server,
            macIP: address ?? "127.0.0.1"
        )
    }

    private func macIP() async -> String? {
        if let cachedMacIP { return cachedMacIP }
        let address = await MacIP.current(shell: shell)
        cachedMacIP = address
        return address
    }

    private func gitSnapshot() async throws -> GitSnapshot {
        async let status = gitOutput(["status", "--porcelain"])
        let arguments = LoginShell.arguments("git -C \(shellQuote(input.sourceDir.path)) diff | shasum", exports: [])
        async let diff = shell.run(arguments.exe, arguments.args, timeout: .seconds(20))
        let statusOutput = try await status
        let diffOutput = try await diff
        guard diffOutput.status == 0 else {
            throw PrepareFailure(.build, lastMessage(diffOutput.out, fallback: "git diff를 확인하지 못했어요"))
        }
        return GitSnapshot(status: statusOutput, diffSHA: diffOutput.out)
    }

    private func gitOutput(_ arguments: [String]) async throws -> String {
        let response = try await runShell(
            step: .build,
            exe: "/usr/bin/git",
            args: ["-C", input.sourceDir.path] + arguments,
            timeout: .seconds(20)
        )
        guard response.status == 0 else {
            throw PrepareFailure(.build, lastMessage(response.out, fallback: "git 상태를 확인하지 못했어요"))
        }
        return response.out
    }

    private func runShell(
        step: PrepareStep,
        exe: String,
        args: [String],
        timeout: Duration
    ) async throws -> (status: Int32, out: String) {
        try checkCancellation()
        appendLog(step, ([exe] + args).joined(separator: " "))
        do {
            let response = try await shell.run(exe, args, timeout: timeout)
            appendLog(step, response.out)
            try checkCancellation()
            return response
        } catch {
            throw PrepareFailure(step, error.localizedDescription)
        }
    }

    private func waitForProcess(
        _ process: ManagedProcess,
        step: PrepareStep,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try checkCancellation()
            await sleepForPoll()
        }
        try checkCancellation()
        if process.isRunning {
            await process.terminate()
            throw PrepareFailure(step, "\(step.rawValue) 작업이 제한 시간 안에 끝나지 않았어요")
        }
        return process.tail(lines: 30)
    }

    private func sleepForPoll() async {
        let task = Task<Void, Never> { [clock, pollInterval] in
            try? await clock.sleep(for: pollInterval)
        }
        sleepTask = task
        await task.value
        sleepTask = nil
    }

    private func checkCancellation() throws {
        if cancelled {
            throw CancellationError()
        }
    }

    private func emit(_ event: PrepareEvent) {
        continuation.yield(event)
    }

    private func appendLog(_ step: PrepareStep, _ text: String) {
        guard !text.isEmpty else { return }
        log.append(step: step, text)
        emit(.log(SecretRedactor.redact(text, values: Self.secretValues(input: input))))
    }

    private func finish(succeeded: Bool, failure: String?) {
        guard !finishedForAttempt else { return }
        finishedForAttempt = true
        result.durationSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        result.succeeded = succeeded
        result.failure = failure
        emit(.finished(result))
    }

    private static func launchArtemis(
        input: PrepareInput,
        launcher: ProcessLauncher
    ) throws -> ManagedProcess {
        let port = input.artemisURL.port ?? 8100
        var exports = [("ARTEMIS_HOME", input.artemisHome.path)]
        if let tracesDir = input.tracesDir {
            exports.append(("ARTEMIS_TRACES_DIR", tracesDir.path))
        }
        let command = "cd \"$ARTEMIS_HOME\" && uv run artemis ui --port \(port)"
        let arguments = LoginShell.arguments(command, exports: exports)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let logURL = support.appending(path: "QATwin/artemis.log")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try launcher.launch(
            exe: arguments.exe,
            args: arguments.args,
            cwd: input.artemisHome,
            logURL: logURL
        )
    }

    private static func artemisFailure(process: ManagedProcess, port: Int) -> String {
        let output = process.tail(lines: 30)
        if output.localizedCaseInsensitiveContains("address already in use") {
            return "포트 \(port)을 다른 프로세스가 쓰고 있어요"
        }
        return lastMessage(output, fallback: "Artemis 서버가 먼저 종료됐어요")
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func replacingMacIP(_ value: String, with address: String) -> String {
        value.replacingOccurrences(of: "{{mac_ip}}", with: address)
    }

    private static func roles(input: PrepareInput) -> [String: AccountRole] {
        let yaml = (try? String(
            contentsOf: input.projectDir.appending(path: "project.yaml"),
            encoding: .utf8
        )) ?? ""
        return Workspace.accountRoles(projectYAML: yaml)
    }

    private static func secretValues(input: PrepareInput) -> [String] {
        let yaml = (try? String(
            contentsOf: input.projectDir.appending(path: "project.yaml"),
            encoding: .utf8
        )) ?? ""
        return SecretKeys.values(
            envURL: input.projectDir.appending(path: ".env"),
            accountKeys: Set(Workspace.accountEnvKeys(projectYAML: yaml))
        )
    }
}

private struct PrepareFailure: Error {
    let step: PrepareStep
    let message: String

    init(_ step: PrepareStep, _ message: String) {
        self.step = step
        self.message = message
    }
}

private struct GitSnapshot: Equatable {
    let status: String
    let diffSHA: String
}

private func lastMessage(_ output: String, fallback: String) -> String {
    output.split(whereSeparator: \ .isNewline)
        .reversed()
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? fallback
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
