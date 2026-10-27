import Foundation
@testable import QATwinCore

final class RecordingShell: ShellRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(match: String, status: Int32, out: String)]
    private(set) var calls: [(exe: String, args: [String])] = []

    init(responses: [(match: String, status: Int32, out: String)] = []) {
        self.responses = responses
    }

    func run(
        _ exe: String,
        _ args: [String],
        timeout: Duration
    ) async throws -> (status: Int32, out: String) {
        lock.withLock {
            calls.append((exe, args))
        }
        let command = ([exe] + args).joined(separator: " ")
        return lock.withLock {
            guard let index = responses.firstIndex(where: { command.contains($0.match) }) else {
                return (0, "")
            }
            let response = responses[index]
            if responses[(index + 1)...].contains(where: { $0.match == response.match }) {
                responses.remove(at: index)
            }
            return (response.status, response.out)
        }
    }
}

final class FakeArtemisAPI: ArtemisAPI, @unchecked Sendable {
    private var deviceResponses: [Result<[ArtemisDevice], ArtemisError>]
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
    /// true면 취소된 Task 안의 stop은 URLSession처럼 보내지 못하고 실패한다.
    var failsStopWhenCancelled = false

    init(
        goalIDs: [String: String] = [:],
        sessionIDs: [String: String] = [:],
        states: [String: [SessionState]] = [:],
        usage: [String: Usage] = [:],
        runErrors: [String: ArtemisError] = [:],
        stateFailures: [String: Int] = [:],
        saveDelay: Duration? = nil,
        deviceResponses: [Result<[ArtemisDevice], ArtemisError>] = [.success([])]
    ) {
        self.deviceResponses = deviceResponses
        self.goalIDs = goalIDs
        self.stateFailures = stateFailures
        self.runErrors = runErrors
        self.saveDelay = saveDelay
        self.sessionIDs = sessionIDs
        self.stateResponses = states
        self.usageResponses = usage
    }

    func devices() async throws -> [ArtemisDevice] {
        try withLock {
            guard let response = deviceResponses.first else {
                return []
            }
            if deviceResponses.count > 1 {
                deviceResponses.removeFirst()
            }
            return try response.get()
        }
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
        if failsStopWhenCancelled { try Task.checkCancellation() }
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

func tempDir(_ prefix: String = "QATwinCoreTests") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "\(prefix)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
