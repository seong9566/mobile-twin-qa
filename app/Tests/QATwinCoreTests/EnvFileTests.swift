import Foundation
import Testing
@testable import QATwinCore

private func envTempDir() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreEnvFileTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func tempFile(_ contents: String) -> URL {
    let url = envTempDir().appending(path: ".env")
    try! contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func upsertPreservesOtherLines() throws {
    let url = tempFile("# 주석\nA=1\n\nB=\"two\"\n")
    try EnvFile(url: url).upsert(key: "A", value: "새=값 한글")
    #expect(try String(contentsOf: url, encoding: .utf8) == "# 주석\nA=새=값 한글\n\nB=\"two\"\n")
}

@Test func upsertAppendsAndCreates600() throws {
    let url = envTempDir().appending(path: ".env")
    try EnvFile(url: url).upsert(key: "DEMO_USER_ID", value: "u1")
    #expect(try String(contentsOf: url, encoding: .utf8) == "DEMO_USER_ID=u1\n")
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
}

@Test func presentKeysIgnoresEmptyAndComments() {
    #expect(EnvFile(url: tempFile("# X=1\nA=\nB=\"\"\nC=3\n")).presentKeys() == ["C"])
}

@Test func rejectsNewlineAndBadKey() {
    #expect(throws: EnvFileError.newlineInValue) {
        try EnvFile(url: tempFile("")).upsert(key: "A", value: "a\nb")
    }
    #expect(throws: EnvFileError.invalidKey) {
        try EnvFile(url: tempFile("")).upsert(key: "a-b", value: "x")
    }
}
