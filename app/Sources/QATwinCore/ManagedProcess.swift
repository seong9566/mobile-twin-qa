import Darwin
import Foundation

public enum LoginShell {
    public static func command(_ body: String, exports: [(String, String)]) -> String {
        let prefix = exports.map { key, value in
            let quoted = value.replacingOccurrences(of: "'", with: "'\\''")
            return "export \(key)='\(quoted)'"
        }.joined(separator: "; ")
        return prefix.isEmpty ? body : "\(prefix); \(body)"
    }

    public static func arguments(
        _ body: String,
        exports: [(String, String)]
    ) -> (exe: String, args: [String]) {
        let exe = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (exe, ["-lic", command(body, exports: exports)])
    }
}

public final class ManagedProcess: @unchecked Sendable {
    private let logURL: URL?
    private let pipe = Pipe()
    private let process = Process()
    private let state = ManagedProcessState()

    public init(exe: String, args: [String], cwd: URL, logURL: URL?) {
        self.logURL = logURL
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.executableURL = URL(fileURLWithPath: exe)
        process.standardError = pipe
        process.standardOutput = pipe
        // 로그인 셸(-i)이 입력을 기다리지 않게 stdin은 비운다.
        process.standardInput = FileHandle.nullDevice
    }

    public func start() throws {
        if let logURL {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            state.setLogHandle(handle)
        }

        process.terminationHandler = { [state] terminated in
            state.exited(status: terminated.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            state.closeLog()
            throw error
        }
        state.started()

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        DispatchQueue.global().async { [state] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
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
    }

    public var isRunning: Bool {
        state.isRunning
    }

    public var exitStatus: Int32? {
        state.exitStatus
    }

    public func tail(lines: Int) -> String {
        state.tail(lines: lines)
    }

    public func terminate() async {
        guard state.hasStarted else { return }
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        Darwin.kill(ownsGroup ? -pid : pid, SIGTERM)
        try? await Task.sleep(for: .seconds(2))
        if ownsGroup, Darwin.kill(-pid, 0) == 0 {
            Darwin.kill(-pid, SIGKILL)
        } else if process.isRunning {
            Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class ManagedProcessState: @unchecked Sendable {
    private static let outputLimit = 64 * 1024

    private var ended = false
    private var logHandle: FileHandle?
    private let lock = NSLock()
    private var output = Data()
    private var startedFlag = false
    private var status: Int32?

    var hasStarted: Bool {
        lock.withLock { startedFlag }
    }

    var isRunning: Bool {
        lock.withLock { startedFlag && (status == nil || !ended) }
    }

    var exitStatus: Int32? {
        lock.withLock { status }
    }

    func setLogHandle(_ handle: FileHandle) {
        lock.withLock { logHandle = handle }
    }

    func started() {
        lock.withLock { startedFlag = true }
    }

    func exited(status: Int32) {
        lock.withLock { self.status = status }
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        lock.withLock {
            let data = Data(bytes)
            try? logHandle?.write(contentsOf: data)
            output.append(data)
            if output.count > Self.outputLimit {
                output.removeFirst(output.count - Self.outputLimit)
            }
        }
    }

    func reachedEnd() {
        lock.withLock {
            ended = true
            try? logHandle?.close()
            logHandle = nil
        }
    }

    func closeLog() {
        lock.withLock {
            try? logHandle?.close()
            logHandle = nil
        }
    }

    func tail(lines: Int) -> String {
        guard lines > 0 else { return "" }
        let text = lock.withLock { String(decoding: output, as: UTF8.self) }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        return parts.suffix(lines).joined(separator: "\n")
    }
}
