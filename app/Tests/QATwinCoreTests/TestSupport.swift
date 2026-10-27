import Foundation
@testable import QATwinCore

final class RecordingShell: ShellRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(match: String, status: Int32, out: String)]
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
        guard let response = responses.first(where: { command.contains($0.match) }) else {
            return (0, "")
        }
        return (response.status, response.out)
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
