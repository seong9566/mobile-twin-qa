import Foundation
import Testing
@testable import QATwinCore

@Suite struct EnvImportTests {
    @Test func envImportRefusesTrackedFile() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "A=1\n".write(to: directory.appending(path: ".env"), atomically: true, encoding: .utf8)
        let shell = RecordingShell(responses: [("ls-files --error-unmatch", 0, ".env\n")])

        await #expect(throws: EnvImport.Refusal.tracked(directory.appending(path: ".env").path)) {
            try await EnvImport.candidates(sourceDir: directory, envSource: ".env", shell: shell)
        }
    }

    @Test func envImportDefaultsToExampleKeys() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "A=1\nB=2\n".write(to: directory.appending(path: ".env"), atomically: true, encoding: .utf8)
        try "A=\n".write(to: directory.appending(path: ".env.example"), atomically: true, encoding: .utf8)
        let shell = RecordingShell(responses: [("ls-files --error-unmatch", 1, "error: pathspec")])

        let candidates = try await EnvImport.candidates(sourceDir: directory, envSource: ".env", shell: shell)

        #expect(candidates == [
            EnvImport.Candidate(key: "A", defaultChecked: true),
            EnvImport.Candidate(key: "B", defaultChecked: false),
        ])
    }

    @Test func envImportApplyKeepsOtherLines() throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.env")
        let target = directory.appending(path: "target.env")
        try "A=new\nB=skip\n".write(to: source, atomically: true, encoding: .utf8)
        try "# 메모\nA=old\nC=keep\n".write(to: target, atomically: true, encoding: .utf8)

        try EnvImport.apply(keys: ["A"], from: source, to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "# 메모\nA=new\nC=keep\n")
    }
}
