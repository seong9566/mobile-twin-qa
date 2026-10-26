import Foundation

public protocol ShellRunner: Sendable {
    func run(_ exe: String, _ args: [String]) async throws -> (status: Int32, out: String)
}

public struct ProcessShellRunner: ShellRunner {
    public init() {}

    public func run(_ exe: String, _ args: [String]) async throws -> (status: Int32, out: String) {
        let pipe = Pipe()
        let process = Process()
        process.arguments = args
        process.executableURL = URL(fileURLWithPath: exe)
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
