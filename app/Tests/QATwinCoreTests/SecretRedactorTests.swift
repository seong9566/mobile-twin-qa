import Foundation
import Testing
@testable import QATwinCore

/// 역슬래시+u. 파일에 이스케이프 글자를 그대로 두지 않으려고 이어 붙인다.
private let u = #"\"# + "u"

@Test func redactsJSONEscapedValues() {
    let value = #"p"a\s/é"#
    let text = #"{"a":"p\"a\\s/é","b":"p\"a\\s\/é","c":"p\"a\\s/"# + u + #"00e9","d":"p\\\"a\\\\s/é"}"#
    #expect(SecretRedactor.redact(text, values: [value]) == #"{"a":"****","b":"****","c":"****","d":"****"}"#)
}

@Test func redactsWhatPythonAndSwiftJSONProduce() throws {
    let value = "pw\u{08}\u{0C}\u{7F}😀/é"
    // Python json.dumps(ensure_ascii=True) 출력.
    let python = #"{"pw": "pw\b\f"# + u + "007f" + u + "d83d" + u + #"de00/"# + u + #"00e9"}"#
    let swift = String(decoding: try JSONEncoder().encode(["pw": value]), as: UTF8.self)
    #expect(SecretRedactor.redact(python, values: [value]) == #"{"pw": "****"}"#)
    #expect(SecretRedactor.redact(swift, values: [value]) == #"{"pw":"****"}"#)
}

@Test func skipsValuesShorterThanMinimum() {
    #expect(SecretRedactor.redact("ab abc", values: ["ab"]) == "ab abc")
}

@Test func masksFragmentsAfterTruncationMarkerAndAtLastLineEnd() {
    let text = "…retXYZ cut line\n2026 normal sec\n…cretXYZ still writing secre"
    #expect(SecretRedactor.redact(text, values: ["secretXYZ"]) == text)
    #expect(
        SecretRedactor.redact(text, values: ["secretXYZ", "abc2026"], truncationMarker: "…")
            == "…**** cut line\n2026 normal sec\n…**** still writing ****"
    )
}

@Test func masksEscapedFragmentAtLastLineEnd() {
    #expect(SecretRedactor.redact(#"{"pw":"p\"a\\"#, values: [#"p"a\s"#], truncationMarker: "…") == #"{"pw":"****"#)
}

@Test func truncatedLineKeepsMarkerAfterItEnds() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "QATwinRedactTail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "log.txt")
    let secret = "secretXYZ"
    // 잘린 지점이 비밀값 한가운데에 오도록 길이를 맞춘다.
    let filler = String(repeating: "x", count: LogTailReader.pendingLimit - 6)
    try Data((secret + filler).utf8).write(to: url)
    var reader = LogTailReader(url: url)
    reader.read()
    try FileHandle(forWritingTo: url).appendAndClose(Data("\nnext\n".utf8))
    reader.read()
    let shown = SecretRedactor.redact(reader.tail, values: [secret], truncationMarker: LogTailReader.truncationMarker)
    #expect(shown.hasPrefix("…****x"))
    #expect(!shown.contains("XYZ"))
}

private extension FileHandle {
    func appendAndClose(_ data: Data) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: data)
    }
}
