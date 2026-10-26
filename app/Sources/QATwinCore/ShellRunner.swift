import Darwin
import Foundation

public protocol ShellRunner: Sendable {
    func run(_ exe: String, _ args: [String], timeout: Duration) async throws -> (status: Int32, out: String)
}

extension ShellRunner {
    public func run(_ exe: String, _ args: [String]) async throws -> (status: Int32, out: String) {
        try await run(exe, args, timeout: .seconds(20))
    }
}

public enum ShellRunnerError: Error, Equatable, Sendable, LocalizedError {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            "명령이 제한 시간 안에 끝나지 않아 중단했어요."
        }
    }
}

public struct ProcessShellRunner: ShellRunner {
    public init() {}

    public func run(
        _ exe: String,
        _ args: [String],
        timeout: Duration
    ) async throws -> (status: Int32, out: String) {
        let pipe = Pipe()
        let process = Process()
        process.arguments = args
        process.executableURL = URL(fileURLWithPath: exe)
        process.standardError = pipe
        process.standardOutput = pipe

        return try await withCheckedThrowingContinuation { continuation in
            let state = ShellRunState(continuation: continuation)
            process.terminationHandler = { terminated in
                state.exited(status: terminated.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                state.fail(error)
                return
            }

            // 파이프 버퍼가 차서 자식이 멈추지 않게 출력은 별도 스레드에서 끝까지 읽는다.
            DispatchQueue.global().async {
                state.read(pipe.fileHandleForReading.readDataToEndOfFile())
            }

            let (seconds, attoseconds) = timeout.components
            let delay = Double(seconds) + Double(attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                guard state.timeOut() else { return }
                let pid = process.processIdentifier
                Darwin.kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        Darwin.kill(pid, SIGKILL)
                    }
                }
            }
        }
    }
}

private final class ShellRunState: @unchecked Sendable {
    private var continuation: CheckedContinuation<(status: Int32, out: String), Error>?
    private let lock = NSLock()
    private var output: Data?
    private var status: Int32?

    init(continuation: CheckedContinuation<(status: Int32, out: String), Error>) {
        self.continuation = continuation
    }

    func exited(status: Int32) {
        lock.withLock { self.status = status }
        finishIfDone()
    }

    func read(_ data: Data) {
        lock.withLock { output = data }
        finishIfDone()
    }

    func fail(_ error: Error) {
        lock.withLock { takeContinuation() }?.resume(throwing: error)
    }

    /// 아직 끝나지 않았으면 시간 초과로 끝내고 true를 돌려준다.
    func timeOut() -> Bool {
        guard let continuation = lock.withLock({ takeContinuation() }) else { return false }
        continuation.resume(throwing: ShellRunnerError.timedOut)
        return true
    }

    private func finishIfDone() {
        let done: (CheckedContinuation<(status: Int32, out: String), Error>, Int32, Data)? = lock.withLock {
            guard let status, let output, let continuation = takeContinuation() else { return nil }
            return (continuation, status, output)
        }
        guard let (continuation, status, output) = done else { return }
        continuation.resume(returning: (status, String(decoding: output, as: UTF8.self)))
    }

    private func takeContinuation() -> CheckedContinuation<(status: Int32, out: String), Error>? {
        defer { continuation = nil }
        return continuation
    }
}
