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

            // 파이프 버퍼가 차서 자식이 멈추지 않게 출력은 별도 스레드에서 EOF까지 읽는다.
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            DispatchQueue.global().async {
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        state.append(chunk[..<count])
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                state.reachedEnd()
            }

            let (seconds, attoseconds) = timeout.components
            let delay = Double(seconds) + Double(attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                // 프로세스는 끝났는데 손자 프로세스가 파이프를 물고 있으면 읽은 데까지로 끝낸다.
                if !process.isRunning {
                    state.finishWithoutEnd(status: process.terminationStatus)
                    return
                }
                guard state.timeOut() else { return }
                terminateGroup(of: process)
            }
        }
    }
}

/// Process는 자식을 자기 프로세스 그룹에 두므로 그룹째 끝낸다. 그룹이 아니면 그 프로세스만 끝낸다.
private func terminateGroup(of process: Process) {
    let pid = process.processIdentifier
    let ownsGroup = getpgid(pid) == pid
    Darwin.kill(ownsGroup ? -pid : pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if ownsGroup, Darwin.kill(-pid, 0) == 0 {
            Darwin.kill(-pid, SIGKILL)
        } else if process.isRunning {
            Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class ShellRunState: @unchecked Sendable {
    private var continuation: CheckedContinuation<(status: Int32, out: String), Error>?
    private var ended = false
    private let lock = NSLock()
    private var output = Data()
    private var status: Int32?

    init(continuation: CheckedContinuation<(status: Int32, out: String), Error>) {
        self.continuation = continuation
    }

    func exited(status: Int32) {
        lock.withLock { self.status = status }
        finishIfDone()
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        lock.withLock { output.append(contentsOf: bytes) }
    }

    func reachedEnd() {
        lock.withLock { ended = true }
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

    /// 프로세스가 끝났으면 EOF를 기다리지 않고 지금까지 읽은 출력으로 끝낸다.
    func finishWithoutEnd(status: Int32) {
        let done: (CheckedContinuation<(status: Int32, out: String), Error>, Int32, Data)? = lock.withLock {
            guard let continuation = takeContinuation() else { return nil }
            return (continuation, self.status ?? status, output)
        }
        guard let (continuation, status, output) = done else { return }
        continuation.resume(returning: (status, String(decoding: output, as: UTF8.self)))
    }

    private func finishIfDone() {
        let done: (CheckedContinuation<(status: Int32, out: String), Error>, Int32, Data)? = lock.withLock {
            guard ended, let status, let continuation = takeContinuation() else { return nil }
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
