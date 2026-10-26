import Foundation

public enum ScenarioRunState: Codable, Equatable, Sendable {
    case waiting
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

    public init(
        plan: String,
        deviceSerial: String,
        server: String,
        order: [String],
        states: [String: ScenarioRunState],
        usage: Usage
    ) {
        self.plan = plan
        self.deviceSerial = deviceSerial
        self.server = server
        self.order = order
        self.states = states
        self.usage = usage
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
    public nonisolated let runDir: URL
    private let scenarios: [Scenario]
    private let shell: ShellRunner
    private let tracesDir: URL?

    private var completedUsage = emptyUsage()
    private var currentID: String?
    private var currentSessionID: String?
    private var isRunning = false
    private var sessionResults: [String: SessionState] = [:]
    private var stallRearmedAt: [String: Date] = [:]
    private var stallRearmedLogLength: [String: Int] = [:]
    private var lastLogLength: [String: Int] = [:]
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
        clock: any Clock<Duration> = ContinuousClock()
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
        self.runDir = runDir
        self.scenarios = scenarios
        self.shell = shell
        self.stateFile = RunStateFile(
            plan: planRelativePath,
            deviceSerial: deviceSerial,
            server: server,
            order: order,
            states: Dictionary(uniqueKeysWithValues: order.map { ($0, .waiting) }),
            usage: emptyUsage()
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

    public func retry(id: String) async {
        guard !isRunning,
              let scenario = scenarios.first(where: { $0.id == id }),
              prepareRetryArtifacts(id: id)
        else {
            continuation.yield(.finished)
            return
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
        stallRearmedLogLength[scenario.id] = nil
        lastLogLength[scenario.id] = nil
        stallWarningsSent.remove(scenario.id)
        if scenario.grade == .B {
            continuation.yield(
                .humanAction(id: scenario.id, note: scenario.gradeNote ?? "사람이 할 동작")
            )
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

            let log = traceLog(sessionID: sessionID)
            if sessionState == .running, log.text == nil {
                traceLogMissingCount += 1
                if traceLogMissingCount == 6, !didEmitTraceLogMissing {
                    continuation.yield(.traceLogMissing(id: scenario.id))
                    didEmitTraceLogMissing = true
                }
            } else {
                traceLogMissingCount = 0
            }
            if containsSpendLimit(log.text) {
                try? await api.stop(sessionID)
                setState(.held(reason: "API 지출 한도"), for: scenario.id)
                markWaitingAsNotRun(reason: "API 지출 한도")
                continuation.yield(.spendLimitReached)
                currentID = nil
                currentSessionID = nil
                return .spendLimit
            }

            let stallBaseline = [log.modifiedAt, stallRearmedAt[scenario.id]]
                .compactMap { $0 }
                .max()
            lastLogLength[scenario.id] = log.text?.count
            // "계속 기다리기" 뒤에는 그 시점 이후 로그만 본다. 앞에 단계 요약 표지를 붙여 그 뒤의 반복만 세게 한다.
            let stallLog = log.text.map { text -> String in
                guard let offset = stallRearmedLogLength[scenario.id], offset <= text.count else { return text }
                return "Generated summary for Step (계속 기다리기)\n" + String(text.dropFirst(offset))
            }
            if !stallWarningsSent.contains(scenario.id), let signal = StallDetector.evaluate(
                log: stallLog,
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
                currentID = nil
                currentSessionID = nil
                return .continued
            case .running, .unknown:
                break
            }

            try? await clock.sleep(for: pollInterval)
        }
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
        stallRearmedLogLength[id] = lastLogLength[id]
        stallWarningsSent.remove(id)
    }

    private func handleStopRequest(sessionID: String, id: String) async -> Bool {
        guard stopAllRequested || stopCurrentRequested else {
            return false
        }
        try? await api.stop(sessionID)
        setState(.held(reason: "사용자 중지"), for: id)
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

    private func traceLog(sessionID: String) -> (text: String?, modifiedAt: Date?) {
        let url = StallDetector.traceLog(
            sessionID: sessionID,
            artemisHome: artemisHome,
            tracesDir: tracesDir
        )
        let text = try? String(contentsOf: url, encoding: .utf8)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (text, attributes?[.modificationDate] as? Date)
    }

    private func containsSpendLimit(_ log: String?) -> Bool {
        guard let log else {
            return false
        }
        return log.localizedCaseInsensitiveContains(
            "You have reached your specified API usage limits"
        ) || log.localizedCaseInsensitiveContains("enforced_spend_limit_reached")
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

    private func prepareRetryArtifacts(id: String) -> Bool {
        let directory = runDir
            .appending(path: "artifacts", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        let try1 = directory.appending(path: "try1", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: try1.path) else {
            return false
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
            return true
        } catch {
            return false
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
