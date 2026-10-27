import Foundation

public enum ScenarioRunState: Codable, Equatable, Sendable {
    case waiting
    /// 시나리오 직전 앱 데이터 초기화·재로그인 중.
    case preparing
    case running(sessionID: String)
    case finished(sessionID: String, artemis: String)
    case held(reason: String)
    case notRun(reason: String)
}

public struct RunStateFile: Codable {
    public var plan: String
    public var deviceSerial: String
    public var server: String
    public var order: [String]
    public var states: [String: ScenarioRunState]
    public var usage: Usage
    /// 앱이 한 실행 준비 기록. 예전 run-state.json에는 없다.
    public var prepare: PrepareResult?

    public init(
        plan: String,
        deviceSerial: String,
        server: String,
        order: [String],
        states: [String: ScenarioRunState],
        usage: Usage,
        prepare: PrepareResult? = nil
    ) {
        self.plan = plan
        self.deviceSerial = deviceSerial
        self.server = server
        self.order = order
        self.states = states
        self.usage = usage
        self.prepare = prepare
    }
}

/// 시나리오 직전 앱 데이터 초기화·재로그인에 쓰는 값(스펙 5.7·5.8).
public struct ResetContext: Sendable {
    public let package: String
    public let launch: String
    public let permissions: [String]
    public let loginScript: URL
    public let envURL: URL
    public let roles: [String: AccountRole]
    public let chosenRole: String?
    /// LoginPlan.when이 .beforeScenario(id)면 그 id. 초기화 칸이 없어도 그 시나리오 앞에서 로그인한다.
    public let loginBefore: String?

    public init(
        package: String,
        launch: String,
        permissions: [String],
        loginScript: URL,
        envURL: URL,
        roles: [String: AccountRole],
        chosenRole: String?,
        loginBefore: String?
    ) {
        self.package = package
        self.launch = launch
        self.permissions = permissions
        self.loginScript = loginScript
        self.envURL = envURL
        self.roles = roles
        self.chosenRole = chosenRole
        self.loginBefore = loginBefore
    }
}

public enum RunEvent: Equatable, Sendable {
    case state(id: String, ScenarioRunState)
    case usage(Usage)
    case stall(id: String, StallSignal)
    case pollFailing(id: String, reason: String)
    case pollRecovered(id: String)
    case traceLogMissing(id: String)
    case adbUnavailable(id: String)
    case wifiDown(id: String)
    case humanAction(id: String, note: String)
    case spendLimitReached
    case finished
}

/// retry(id:)가 다시 돌리지 못한 이유.
public enum RetryRefusal: Equatable, Sendable {
    case alreadyRetried
    case unknownScenario
    case running
    case moveFailed

    public var reason: String {
        switch self {
        case .alreadyRetried: "이미 try1이 있음"
        case .unknownScenario: "시나리오 없음"
        case .running: "실행 중"
        case .moveFailed: "파일 이동 실패"
        }
    }
}

public actor RunOrchestrator {
    private let adbPath: String?
    private let api: ArtemisAPI
    private let artemisHome: URL
    private let clock: any Clock<Duration>
    private let continuation: AsyncStream<RunEvent>.Continuation
    private let deviceSerial: String
    private nonisolated let eventStream: AsyncStream<RunEvent>
    private let fileManager = FileManager.default
    private let plan: PlanDocument
    private let pollInterval: Duration
    private let reset: ResetContext?
    public nonisolated let runDir: URL
    private let scenarios: [Scenario]
    private let shell: ShellRunner
    private let tracesDir: URL?

    private var completedUsage = emptyUsage()
    private var currentID: String?
    private var currentSessionID: String?
    private var isRunning = false
    public private(set) var lastRetryRefusal: RetryRefusal?
    private var sessionResults: [String: SessionState] = [:]
    private var logReaders: [String: LogTailReader] = [:]
    private var stallRearmedAt: [String: Date] = [:]
    private var stallWarningsSent: Set<String> = []
    private var stateFile: RunStateFile
    private var stopAllRequested = false
    private var stopCurrentRequested = false

    public init(
        api: ArtemisAPI,
        shell: ShellRunner,
        runDir: URL,
        plan: PlanDocument,
        scenarios: [Scenario],
        deviceSerial: String,
        server: String,
        planRelativePath: String,
        artemisHome: URL,
        tracesDir: URL?,
        adbPath: String?,
        pollInterval: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock(),
        reset: ResetContext? = nil,
        prepare: PrepareResult? = nil
    ) {
        let events = AsyncStream<RunEvent>.makeStream()
        let order = scenarios.map(\.id)
        self.adbPath = adbPath
        self.api = api
        self.artemisHome = artemisHome
        self.clock = clock
        self.continuation = events.continuation
        self.deviceSerial = deviceSerial
        self.eventStream = events.stream
        self.plan = plan
        self.pollInterval = pollInterval
        self.reset = reset
        self.runDir = runDir
        self.scenarios = scenarios
        self.shell = shell
        self.stateFile = RunStateFile(
            plan: planRelativePath,
            deviceSerial: deviceSerial,
            server: server,
            order: order,
            states: Dictionary(uniqueKeysWithValues: order.map { ($0, .waiting) }),
            usage: emptyUsage(),
            prepare: prepare
        )
        self.tracesDir = tracesDir
    }

    public nonisolated var events: AsyncStream<RunEvent> {
        eventStream
    }

    public func start() async {
        guard !isRunning else {
            return
        }
        isRunning = true
        writeStateFile()

        for scenario in scenarios {
            if stopAllRequested {
                markWaitingAsNotRun(reason: "사용자 중지")
                break
            }
            guard stateFile.states[scenario.id] == .waiting else {
                continue
            }
            if let prerequisite = scenario.dependsOn.first(where: { sessionResults[$0] != .completed }) {
                setState(.held(reason: "사전 조건 \(prerequisite) 미완료"), for: scenario.id)
                continue
            }
            if await run(scenario) == .spendLimit {
                break
            }
        }

        currentID = nil
        currentSessionID = nil
        isRunning = false
        stopAllRequested = false
        stopCurrentRequested = false
        continuation.yield(.finished)
    }

    public func stopCurrentAsHeld() async {
        guard currentID != nil else {
            return
        }
        stopCurrentRequested = true
    }

    public func stopAll() async {
        stopAllRequested = true
        if currentID == nil {
            markWaitingAsNotRun(reason: "사용자 중지")
        }
    }

    /// 실제로 다시 돌렸으면 true. 돌리지 못했으면 false를 돌려주고 이유를 lastRetryRefusal에 남긴다.
    /// 어느 쪽이든 스트림 소비자를 위해 .finished는 보낸다.
    @discardableResult
    public func retry(id: String) async -> Bool {
        let refusal: RetryRefusal?
        if isRunning {
            refusal = .running
        } else if !scenarios.contains(where: { $0.id == id }) {
            refusal = .unknownScenario
        } else {
            refusal = prepareRetryArtifacts(id: id)
        }
        lastRetryRefusal = refusal
        guard refusal == nil, let scenario = scenarios.first(where: { $0.id == id }) else {
            continuation.yield(.finished)
            return false
        }

        isRunning = true
        stopAllRequested = false
        stopCurrentRequested = false
        setState(.waiting, for: id)
        _ = await run(scenario)
        currentID = nil
        currentSessionID = nil
        isRunning = false
        stopAllRequested = false
        stopCurrentRequested = false
        continuation.yield(.finished)
        return true
    }

    static let maxPollFailures = 3

    private enum RunResult: Equatable {
        case continued
        case spendLimit
    }

    private func run(_ scenario: Scenario) async -> RunResult {
        stopCurrentRequested = false
        currentID = scenario.id
        stallRearmedAt[scenario.id] = nil
        logReaders[scenario.id] = nil
        stallWarningsSent.remove(scenario.id)
        if scenario.grade == .B {
            continuation.yield(
                .humanAction(id: scenario.id, note: scenario.gradeNote ?? "사람이 할 동작")
            )
        }

        if let failure = await resetIfNeeded(scenario) {
            setState(.held(reason: "초기화 실패: \(failure)"), for: scenario.id)
            currentID = nil
            return .continued
        }

        let sessionID: String
        do {
            sessionID = try await api.run(
                goal: scenario.goal,
                options: plan.runOptions(for: scenario),
                deviceSerial: deviceSerial
            )
        } catch {
            let stopped = stopAllRequested || stopCurrentRequested
            setState(
                .held(reason: stopped ? "사용자 중지" : runErrorReason(error)),
                for: scenario.id
            )
            currentID = nil
            if stopAllRequested {
                markWaitingAsNotRun(reason: "사용자 중지")
            }
            stopCurrentRequested = false
            return .continued
        }

        currentSessionID = sessionID
        logReaders[scenario.id] = LogTailReader(url: StallDetector.traceLog(
            sessionID: sessionID,
            artemisHome: artemisHome,
            tracesDir: tracesDir
        ))
        setState(.running(sessionID: sessionID), for: scenario.id)
        if adbPath == nil {
            continuation.yield(.adbUnavailable(id: scenario.id))
        }
        var didEmitTraceLogMissing = false
        var didEmitWifiDown = false
        var pollFailures = 0
        var traceLogMissingCount = 0
        var currentUsage = emptyUsage()

        while true {
            if await handleStopRequest(sessionID: sessionID, id: scenario.id) {
                return .continued
            }

            let sessionState: SessionState
            do {
                sessionState = try await api.state(sessionID)
                currentUsage = try await api.usage(sessionID)
                updateUsage(current: currentUsage)
            } catch {
                pollFailures += 1
                if pollFailures == Self.maxPollFailures {
                    continuation.yield(
                        .pollFailing(id: scenario.id, reason: runErrorReason(error))
                    )
                }
                try? await clock.sleep(for: pollInterval)
                continue
            }
            if pollFailures >= Self.maxPollFailures {
                continuation.yield(.pollRecovered(id: scenario.id))
            }
            pollFailures = 0

            if await handleStopRequest(sessionID: sessionID, id: scenario.id) {
                return .continued
            }

            let log = readTraceLog(id: scenario.id)
            if sessionState == .running, !log.exists {
                traceLogMissingCount += 1
                if traceLogMissingCount == 6, !didEmitTraceLogMissing {
                    continuation.yield(.traceLogMissing(id: scenario.id))
                    didEmitTraceLogMissing = true
                }
            } else {
                traceLogMissingCount = 0
            }
            if log.exists, log.reader?.containsSpendLimit == true {
                try? await api.stop(sessionID)
                setState(.held(reason: "API 지출 한도"), for: scenario.id)
                markWaitingAsNotRun(reason: "API 지출 한도")
                continuation.yield(.spendLimitReached)
                logReaders[scenario.id] = nil
                currentID = nil
                currentSessionID = nil
                return .spendLimit
            }

            let stallBaseline = [log.modifiedAt, stallRearmedAt[scenario.id]]
                .compactMap { $0 }
                .max()
            // "계속 기다리기" 뒤에는 그 시점 이후 로그만 본다(rearmStall이 리더에 기준점을 남긴다).
            if !stallWarningsSent.contains(scenario.id), let signal = StallDetector.evaluate(
                idleCount: log.exists ? log.reader?.idleCount : nil,
                modifiedAt: stallBaseline,
                now: Date()
            ) {
                continuation.yield(.stall(id: scenario.id, signal))
                stallWarningsSent.insert(scenario.id)
            }

            if adbPath != nil {
                if await isWifiDown() {
                    if !didEmitWifiDown {
                        continuation.yield(.wifiDown(id: scenario.id))
                        didEmitWifiDown = true
                    }
                } else {
                    didEmitWifiDown = false
                }
            }

            switch sessionState {
            case .completed, .failed, .cancelled:
                let artifacts = runDir
                    .appending(path: "artifacts", directoryHint: .isDirectory)
                    .appending(path: scenario.id, directoryHint: .isDirectory)
                _ = try? await api.saveArtifacts(sessionID, to: artifacts)
                completedUsage = addUsage(completedUsage, currentUsage)
                updateUsage(current: emptyUsage())
                sessionResults[scenario.id] = sessionState
                setState(
                    .finished(sessionID: sessionID, artemis: sessionState.rawValue),
                    for: scenario.id
                )
                logReaders[scenario.id] = nil
                currentID = nil
                currentSessionID = nil
                return .continued
            case .running, .unknown:
                break
            }

            try? await clock.sleep(for: pollInterval)
        }
    }

    /// 초기화 칸이 있거나 처음 로그인할 시나리오면 `POST /api/run` 전에 앱을 다시 준비한다. 실패하면 이유를 돌려준다.
    private func resetIfNeeded(_ scenario: Scenario) async -> String? {
        guard let reset, let adbPath,
              scenario.resetsAppData || scenario.id == reset.loginBefore
        else { return nil }
        setState(.preparing, for: scenario.id)
        func adb(_ args: [String], timeout: Duration) async -> (status: Int32, out: String)? {
            try? await shell.run(adbPath, ["-s", deviceSerial] + args, timeout: timeout)
        }
        if scenario.resetsAppData {
            guard let cleared = await adb(["shell", "pm", "clear", reset.package], timeout: .seconds(30)),
                  cleared.status == 0
            else { return "앱 데이터를 지우지 못했어요" }
            // 개별 권한 실패는 실패가 아니다(스펙 5.7). adb가 끊기면 다음 명령에서 드러난다.
            for permission in reset.permissions {
                _ = await adb(["shell", "pm", "grant", reset.package, permission], timeout: .seconds(30))
            }
        }
        guard let launched = await adb(["shell", "am", "start", "-n", reset.launch], timeout: .seconds(20)),
              launched.status == 0
        else { return "앱을 실행하지 못했어요" }
        guard PlanDocument.needsLogin(scenario) else { return nil }
        guard let roleKey = LoginPlan.role(for: scenario, chosenRole: reset.chosenRole, roles: reset.roles),
              let role = reset.roles[roleKey]
        else { return "로그인할 역할이 없어요" }
        let arguments = [
            reset.loginScript.path, deviceSerial, reset.envURL.path, role.idEnv, role.passwordEnv,
            "--tap", "로그인", "--wait", "50",
        ]
        for attempt in 0..<2 {
            // GUI 앱의 PATH에는 adb가 없다. 로그인 셸로 부르고 adb 폴더를 PATH 앞에 둔다.
            let body = "export PATH=\"$QA_ADB_DIR:$PATH\"; bash " + arguments.map(Self.shellQuote).joined(separator: " ")
            let shellCall = LoginShell.arguments(body, exports: [("QA_ADB_DIR", URL(fileURLWithPath: adbPath).deletingLastPathComponent().path)])
            guard let result = try? await shell.run(shellCall.exe, shellCall.args, timeout: .seconds(120)) else {
                return "로그인이 120초 안에 끝나지 않았어요"
            }
            switch LoginOutcome.interpret(status: result.status, output: result.out, freshInstallOrReset: scenario.resetsAppData) {
            case .loggedIn, .alreadyLoggedIn:
                return nil
            case .retryOnce(let message):
                if attempt == 1 { return message }
            case .failed(let message):
                return message.isEmpty ? "로그인하지 못했어요" : message
            }
        }
        return "로그인하지 못했어요"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setState(_ state: ScenarioRunState, for id: String) {
        guard stateFile.states[id] != state else {
            return
        }
        stateFile.states[id] = state
        writeStateFile()
        continuation.yield(.state(id: id, state))
    }

    public func rearmStall(id: String) {
        guard currentID == id else {
            return
        }
        stallRearmedAt[id] = Date()
        if logReaders[id]?.hasRead == true {
            logReaders[id]?.markIdleBaseline()
        }
        stallWarningsSent.remove(id)
    }

    private func handleStopRequest(sessionID: String, id: String) async -> Bool {
        guard stopAllRequested || stopCurrentRequested else {
            return false
        }
        try? await api.stop(sessionID)
        setState(.held(reason: "사용자 중지"), for: id)
        logReaders[id] = nil
        currentID = nil
        currentSessionID = nil
        if stopAllRequested {
            markWaitingAsNotRun(reason: "사용자 중지")
        }
        stopCurrentRequested = false
        return true
    }

    private func updateUsage(current: Usage) {
        let usage = addUsage(completedUsage, current)
        stateFile.usage = usage
        writeStateFile()
        continuation.yield(.usage(usage))
    }

    private func markWaitingAsNotRun(reason: String) {
        for id in stateFile.order where stateFile.states[id] == .waiting {
            setState(.notRun(reason: reason), for: id)
        }
    }

    private func writeStateFile() {
        do {
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stateFile)
            try data.write(to: runDir.appending(path: "run-state.json"), options: .atomic)
        } catch {
            return
        }
    }

    /// 지난번 이후 새로 붙은 로그만 읽는다. 읽지 못했으면 exists가 false다.
    private func readTraceLog(id: String) -> (exists: Bool, reader: LogTailReader?, modifiedAt: Date?) {
        guard logReaders[id] != nil else {
            return (false, nil, nil)
        }
        let exists = logReaders[id]?.read() ?? false
        let reader = logReaders[id]
        let attributes = reader.flatMap { try? fileManager.attributesOfItem(atPath: $0.url.path) }
        return (exists, reader, attributes?[.modificationDate] as? Date)
    }

    private func isWifiDown() async -> Bool {
        guard let adbPath else {
            return false
        }
        guard let result = try? await shell.run(
            adbPath,
            ["-s", deviceSerial, "shell", "cmd", "wifi", "status"]
        ) else {
            return false
        }
        return result.out.localizedCaseInsensitiveContains("Wifi is disabled")
            || result.out.localizedCaseInsensitiveContains("not connected")
    }

    private func runErrorReason(_ error: Error) -> String {
        guard let error = error as? ArtemisError else {
            return "Artemis 오류 -1"
        }
        switch error {
        case .deviceLocked:
            return "폰 잠김(409)"
        case .unreachable:
            return "Artemis 응답 없음"
        case let .http(code):
            return "Artemis 오류 \(code)"
        case .badResponse:
            return "Artemis 오류 응답"
        }
    }

    private func prepareRetryArtifacts(id: String) -> RetryRefusal? {
        let directory = runDir
            .appending(path: "artifacts", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        let try1 = directory.appending(path: "try1", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: try1.path) else {
            return .alreadyRetried
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            try fileManager.createDirectory(at: try1, withIntermediateDirectories: true)
            for item in contents {
                try fileManager.moveItem(at: item, to: try1.appending(path: item.lastPathComponent))
            }
            return nil
        } catch {
            return .moveFailed
        }
    }
}

private func emptyUsage() -> Usage {
    Usage(llm_calls: 0, prompt_tokens: 0, completion_tokens: 0)
}

private func addUsage(_ lhs: Usage, _ rhs: Usage) -> Usage {
    Usage(
        llm_calls: lhs.llm_calls + rhs.llm_calls,
        prompt_tokens: lhs.prompt_tokens + rhs.prompt_tokens,
        completion_tokens: lhs.completion_tokens + rhs.completion_tokens
    )
}
