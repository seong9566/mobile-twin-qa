import Foundation

public struct PrepareLog: Sendable {
    private let state: PrepareLogState

    public init(url: URL, secrets: [String]) {
        state = PrepareLogState(url: url, secrets: secrets)
    }

    public func append(step: PrepareStep, _ text: String) {
        state.append(step: step, text)
    }

    public func move(toRunDir runDir: URL) throws {
        try state.move(toRunDir: runDir)
    }

    public static func url(project: ProjectRef, runName: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appending(path: "QATwin/prepare-logs", directoryHint: .isDirectory)
            .appending(path: "\(project.category.rawValue)_\(project.name)__\(runName).log")
    }
}

private final class PrepareLogState: @unchecked Sendable {
    private let lock = NSLock()
    private let secrets: [String]
    private var url: URL

    init(url: URL, secrets: [String]) {
        self.url = url
        self.secrets = secrets
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func append(step: PrepareStep, _ text: String) {
        lock.withLock {
            let redacted = SecretRedactor.redact(text, values: secrets)
            let prefix = "\(Self.timestamp())  \(step.rawValue)  "
            let lines = redacted.components(separatedBy: .newlines)
                .map { prefix + $0 }
                .joined(separator: "\n") + "\n"
            guard let data = lines.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url)
            else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    func move(toRunDir runDir: URL) throws {
        try lock.withLock {
            let artifacts = runDir.appending(path: "artifacts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let destination = artifacts.appending(path: "prepare.log")
            try FileManager.default.moveItem(at: url, to: destination)
            url = destination
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
