import Darwin
import Foundation

public enum Stage: String, Sendable {
    case register = "등록"
    case plan = "계획"
    case prepare = "준비"
    case judge = "판정"
}

public enum StagePrompt {
    public static func register(sourcePath: String, category: ProjectCategory) -> String {
        "앱 실행 모드: \(Stage.register.rawValue)\n/qa-init\n- 소스 경로: \(sourcePath)\n- 분류: \(category.rawValue)"
    }

    public static func plan(project: ProjectRef, scope: String?) -> String {
        var prompt = "앱 실행 모드: \(Stage.plan.rawValue)\n/qa-plan\n- 프로젝트: \(project.id)"
        if let scope {
            prompt += "\n- 범위: \(scope)"
        }
        return prompt
    }

    public static func prepare(
        project: ProjectRef,
        plan: String,
        runDir: String,
        deviceSerial: String,
        server: String,
        scenarioIDs: [String],
        buildInstall: Bool,
        screenshotApproved: Bool
    ) -> String {
        """
        앱 실행 모드: \(Stage.prepare.rawValue)
        /qa-run
        - 프로젝트: \(project.id)
        - 계획: \(plan)
        - 실행 폴더: \(runDir)
        - 기기: \(deviceSerial)
        - 서버: \(server)
        - 시나리오: \(scenarioIDs.joined(separator: ", "))
        - 빌드·설치: \(buildInstall ? "예" : "아니오")
        - 스크린샷 전송 승인: \(project.category == .personal ? "해당 없음(개인)" : (screenshotApproved ? "예" : "아니오"))
        """
    }

    public static func judge(project: ProjectRef, plan: String, runDir: String) -> String {
        """
        앱 실행 모드: \(Stage.judge.rawValue)
        /qa-run
        - 프로젝트: \(project.id)
        - 계획: \(plan)
        - 실행 폴더: \(runDir)
        """
    }
}

public enum ClaudeEvent: Equatable, Sendable {
    case text(String)
    case tool(String)
    case result(isError: Bool, costUSD: Double?, summary: String)
    case rateLimits(ClaudeRateLimits)
}

public enum StreamJSONParser {
    public static func parse(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return []
        }

        if type == "assistant" {
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else {
                return []
            }

            return content.compactMap { item in
                switch item["type"] as? String {
                case "text":
                    guard let text = item["text"] as? String else { return nil }
                    return .text(text)
                case "tool_use":
                    guard let name = item["name"] as? String else { return nil }
                    return .tool(name)
                default:
                    return nil
                }
            }
        }

        if type == "rate_limit_event",
           let info = object["rate_limit_info"] as? [String: Any],
           let windows = info["unifiedWindows"] as? [String: Any] {
            // 헤드리스 출력에 들어오는 구독 사용률(0~1). 상태줄 캐시보다 최신이다.
            func window(_ key: String) -> (pct: Int?, resetsAt: Date?) {
                guard let value = windows[key] as? [String: Any] else { return (nil, nil) }
                let pct = (value["utilization"] as? NSNumber).map { Int(($0.doubleValue * 100).rounded()) }
                let resets = (value["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return (pct, resets)
            }
            let five = window("five_hour"), seven = window("seven_day")
            return [
                .rateLimits(ClaudeRateLimits(
                    fiveHourPct: five.pct,
                    fiveHourResetsAt: five.resetsAt,
                    sevenDayPct: seven.pct,
                    sevenDayResetsAt: seven.resetsAt,
                    updatedAt: Date()
                ))
            ]
        }

        if type == "result",
           let isError = object["is_error"] as? Bool,
           let summary = object["result"] as? String {
            return [
                .result(
                    isError: isError,
                    costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue,
                    summary: summary
                )
            ]
        }

        return []
    }
}

public enum ClaudeRunnerError: Error, Equatable, Sendable, LocalizedError {
    /// stderrTail은 앱 오류 알림에만 보여 주고 파일에는 쓰지 않는다.
    case nonzeroExit(Int32, stderrTail: String)

    static let stderrKeepBytes = 4096
    static let stderrTailMaxCharacters = 300

    public var errorDescription: String? {
        switch self {
        case let .nonzeroExit(status, stderrTail):
            let head = "Claude Code가 종료 코드 \(status)로 끝났어요."
            return stderrTail.isEmpty ? head : head + "\n" + stderrTail
        }
    }

    /// stderr 끝에서 비어 있지 않은 줄을 최대 300자까지 모은다.
    static func stderrTail(from data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var picked: [String] = []
        var length = 0
        for line in lines.reversed() {
            let added = line.count + (picked.isEmpty ? 0 : 1)
            if length + added > stderrTailMaxCharacters {
                if picked.isEmpty {
                    picked.append(String(line.suffix(stderrTailMaxCharacters)))
                }
                break
            }
            picked.append(line)
            length += added
        }
        return picked.reversed().joined(separator: "\n")
    }
}

private final class ClaudeStreamState: @unchecked Sendable {
    private var buffer = Data()
    private let continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation
    private var finished = false
    private let lock = NSLock()
    private var resultSeen = false
    private var stderrBuffer = Data()

    init(continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func receive(_ data: Data) {
        let events: [ClaudeEvent] = lock.withLock {
            guard !finished else { return [] }
            buffer.append(data)
            return events(for: completeLines())
        }
        events.forEach { continuation.yield($0) }
    }

    func receiveStderr(_ data: Data) {
        lock.withLock {
            stderrBuffer.append(data)
            if stderrBuffer.count > ClaudeRunnerError.stderrKeepBytes {
                stderrBuffer = Data(stderrBuffer.suffix(ClaudeRunnerError.stderrKeepBytes))
            }
        }
    }

    func finish(status: Int32) {
        let result: (events: [ClaudeEvent], sawResult: Bool, stderr: Data)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let lines = buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
            buffer.removeAll()
            let events = events(for: lines)
            return (events, resultSeen, stderrBuffer)
        }
        guard let result else { return }
        result.events.forEach { continuation.yield($0) }
        if status != 0 && !result.sawResult {
            continuation.finish(throwing: ClaudeRunnerError.nonzeroExit(
                status,
                stderrTail: ClaudeRunnerError.stderrTail(from: result.stderr)
            ))
        } else {
            continuation.finish()
        }
    }

    func fail(_ error: Error) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldFinish {
            continuation.finish(throwing: error)
        }
    }

    private func completeLines() -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            lines.append(line)
            buffer.removeSubrange(...newline)
        }
        return lines
    }

    private func events(for lines: [String]) -> [ClaudeEvent] {
        lines.flatMap { line in
            StreamJSONParser.parse(line: line).map { event in
                if case .result = event {
                    resultSeen = true
                }
                return event
            }
        }
    }
}

public final class ClaudeRunner: @unchecked Sendable {
    private let environment: [String: String]
    private let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private let workspaceRoot: URL

    public init(
        executable: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude"),
        workspaceRoot: URL,
        environment: [String: String] = [:]
    ) {
        self.environment = environment
        self.executable = executable
        self.workspaceRoot = workspaceRoot
    }

    public func run(prompt: String) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let errorOutput = Pipe()
            let output = Pipe()
            let process = Process()
            let state = ClaudeStreamState(continuation: continuation)
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    self?.cancel()
                }
            }

            process.arguments = [
                "-p",
                prompt,
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "bypassPermissions",
            ]
            process.currentDirectoryURL = workspaceRoot
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
            process.executableURL = executable
            process.standardError = errorOutput
            process.standardOutput = output

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    state.receive(data)
                }
            }
            errorOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    state.receiveStderr(data)
                }
            }
            process.terminationHandler = { [weak self] terminatedProcess in
                output.fileHandleForReading.readabilityHandler = nil
                errorOutput.fileHandleForReading.readabilityHandler = nil
                // 자식(gradle 등)이 stderr를 물고 있어도 멈추지 않게 남은 stderr는 막지 않고 읽는다.
                state.receiveStderr(drainWithoutBlocking(errorOutput.fileHandleForReading))
                // 핸들러가 꺼지기 전에 읽지 못한 마지막 출력(result 이벤트 등)을 마저 읽는다.
                let rest = output.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    state.receive(rest)
                }
                state.finish(status: terminatedProcess.terminationStatus)
                self?.clear(terminatedProcess)
            }

            do {
                lock.withLock {
                    self.process = process
                }
                try process.run()
                // 자식(gradle·adb)까지 한 번에 끝낼 수 있게 자기 프로세스 그룹에 둔다.
                // Process가 이미 그룹을 만들었거나 exec가 끝났으면 EACCES·ESRCH가 나므로 무시한다.
                _ = setpgid(process.processIdentifier, process.processIdentifier)
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errorOutput.fileHandleForReading.readabilityHandler = nil
                clear(process)
                state.fail(error)
            }
        }
    }

    public func cancel() {
        let runningProcess = lock.withLock { process }
        guard let runningProcess, runningProcess.isRunning else {
            return
        }

        let processIdentifier = runningProcess.processIdentifier
        let ownsGroup = getpgid(processIdentifier) == processIdentifier
        if ownsGroup {
            Darwin.kill(-processIdentifier, SIGTERM)
        }
        runningProcess.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            // 그룹에 남은 프로세스가 있으면 강제로 끝낸다. 그룹이 사라졌으면 kill(-pgid, 0)이 실패한다.
            if ownsGroup, Darwin.kill(-processIdentifier, 0) == 0 {
                Darwin.kill(-processIdentifier, SIGKILL)
            }
            self?.killIfRunning(processIdentifier: processIdentifier)
        }
    }

    private func clear(_ terminatedProcess: Process) {
        lock.withLock {
            if process === terminatedProcess {
                process = nil
            }
        }
    }

    private func killIfRunning(processIdentifier: Int32) {
        let shouldKill = lock.withLock {
            process?.processIdentifier == processIdentifier && process?.isRunning == true
        }
        if shouldKill {
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

private func drainWithoutBlocking(_ handle: FileHandle) -> Data {
    let descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { break }
        data.append(contentsOf: chunk[..<count])
    }
    return data
}

public struct ClaudeRateLimits: Equatable, Sendable {
    public var fiveHourPct: Int?
    public var fiveHourResetsAt: Date?
    public var sevenDayPct: Int?
    public var sevenDayResetsAt: Date?
    public var updatedAt: Date

    public static let warnPct = 80

    public static func parse(_ line: String, updatedAt: Date, now: Date) -> ClaudeRateLimits? {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 4,
              let fiveHourPct = percentage(fields[0]),
              let fiveHourReset = resetDate(fields[1]),
              let sevenDayPct = percentage(fields[2]),
              let sevenDayReset = resetDate(fields[3])
        else {
            return nil
        }

        var limits = ClaudeRateLimits(
            fiveHourPct: fiveHourPct,
            fiveHourResetsAt: fiveHourReset,
            sevenDayPct: sevenDayPct,
            sevenDayResetsAt: sevenDayReset,
            updatedAt: updatedAt
        )

        if let reset = limits.fiveHourResetsAt, reset < now {
            limits.fiveHourPct = nil
            limits.fiveHourResetsAt = nil
        }
        if let reset = limits.sevenDayResetsAt, reset < now {
            limits.sevenDayPct = nil
            limits.sevenDayResetsAt = nil
        }
        return limits
    }

    public static func read(
        file: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.cc-sl-ratelimits"),
        now: Date = .now
    ) -> ClaudeRateLimits? {
        guard let line = try? String(contentsOf: file, encoding: .utf8),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let updatedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return parse(line, updatedAt: updatedAt, now: now)
    }

    private static func percentage(_ field: String) -> Int?? {
        if field == "-" {
            return .some(nil)
        }
        guard let value = Double(field), value.isFinite else {
            return nil
        }
        return .some(Int(value.rounded()))
    }

    private static func resetDate(_ field: String) -> Date?? {
        if field == "-" {
            return .some(nil)
        }
        guard let value = Double(field), value.isFinite else {
            return nil
        }
        return .some(Date(timeIntervalSince1970: value))
    }
}
