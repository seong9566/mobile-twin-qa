import Foundation
import Testing
@testable import QATwinCore

private func logTailTempFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreLogTailReaderTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "stdout.log")
}

private func append(_ bytes: [UInt8], to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(bytes))
}

private func append(_ text: String, to url: URL) throws {
    try append(Array(text.utf8), to: url)
}

@Test func logTailReaderReadsOnlyAppendedChunks() throws {
    let url = try logTailTempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var reader = LogTailReader(url: url)

    let missing = reader.read()
    #expect(missing == false)
    try append("Generated summary for Step 1\nLLM stopped", to: url)
    let found = reader.read()
    #expect(found)
    #expect(reader.idleCount == 0)
    try append(" without calling any tool\nLLM stopped without calling any tool\n", to: url)
    reader.read()

    #expect(reader.idleCount == 2)
    #expect(reader.offset == UInt64(try Data(contentsOf: url).count))
    #expect(reader.tail == "Generated summary for Step 1\nLLM stopped without calling any tool\nLLM stopped without calling any tool\n")
    #expect(reader.containsSpendLimit == false)

    try append("Generated summary for Step 2\nERROR: enforced_spend_limit_reached", to: url)
    reader.read()
    #expect(reader.idleCount == 0)
    #expect(reader.containsSpendLimit)
}

@Test func logTailReaderMatchesStallDetectorAndBaseline() throws {
    let url = try logTailTempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let idle = "Generated summary for Step 3\n" + String(repeating: "LLM stopped without calling any tool\n", count: 12)
    try append(idle, to: url)
    var reader = LogTailReader(url: url)
    reader.read()

    let now = Date()
    #expect(
        StallDetector.evaluate(idleCount: reader.idleCount, modifiedAt: now, now: now)
            == StallDetector.evaluate(log: idle, modifiedAt: now, now: now)
    )
    reader.markIdleBaseline()
    #expect(reader.idleCount == 0)
    try append("LLM stopped without calling any tool\n", to: url)
    reader.read()
    #expect(reader.idleCount == 1)
}

@Test func logTailReaderRestartsAfterTruncation() throws {
    let url = try logTailTempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try append("Generated summary for Step 1\nfirst run line\n", to: url)
    var reader = LogTailReader(url: url)
    reader.read()

    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.close()
    try append("new\n", to: url)
    reader.read()

    #expect(reader.tail == "new\n")
    #expect(reader.idleCount == nil)
    #expect(reader.offset == 4)
}

@Test func logTailReaderDecodesKoreanSplitAcrossWrites() throws {
    let url = try logTailTempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let bytes = Array("앞 한글 뒤\n".utf8)
    // "한"(3바이트)의 가운데에서 자른다.
    let split = Array("앞 ".utf8).count + 1
    var reader = LogTailReader(url: url)

    try append(Array(bytes[..<split]), to: url)
    reader.read()
    #expect(reader.tail == "앞 ")
    try append(Array(bytes[split...]), to: url)
    reader.read()

    #expect(reader.tail == "앞 한글 뒤\n")
}

@Test func logTailReaderKeepsLastLines() throws {
    let url = try logTailTempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var reader = LogTailReader(url: url, lineLimit: 3)
    for chunk in 0..<5 {
        try append((0..<4).map { "line \(chunk * 4 + $0)\n" }.joined(), to: url)
        reader.read()
    }

    #expect(reader.tail == "line 18\nline 19\n")
    try append("line 20", to: url)
    reader.read()
    #expect(reader.tail == "line 18\nline 19\nline 20")
}
