import Foundation

/// 계속 늘어나는 로그 파일을 지난번에 읽은 곳부터 이어 읽는다.
/// 멈춤 감지·지출 한도 감지에 필요한 누적 값과 화면에 보일 마지막 줄만 들고 있는다.
public struct LogTailReader: Sendable {
    public let url: URL
    public let lineLimit: Int

    /// 마지막 read()에서 파일을 읽을 수 있었는지.
    public private(set) var exists = false
    /// 한 번이라도 파일을 읽은 적이 있는지.
    public private(set) var hasRead = false
    public private(set) var offset: UInt64 = 0

    private var fileNumber: Int?
    private var lines: [String] = []
    private var pending: [UInt8] = []
    private var committed = Counters()

    private struct Counters: Sendable {
        var idleTotal = 0
        var idleAtSummary: Int?
        var idleAtBaseline: Int?
        var sawSpendLimit = false
    }

    public init(url: URL, lineLimit: Int = 200) {
        self.url = url
        self.lineLimit = lineLimit
    }

    /// 새로 붙은 바이트만 읽는다. 파일이 지난번보다 작아졌거나 바뀌었으면 처음부터 다시 읽는다.
    @discardableResult
    public mutating func read() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            exists = false
            return false
        }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.intValue
        guard let size = try? handle.seekToEnd() else {
            exists = false
            return false
        }
        if size < offset || (fileNumber != nil && number != fileNumber) {
            reset()
        }
        fileNumber = number
        exists = true
        hasRead = true
        guard size > offset else { return true }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            append(data)
        } catch {
            return true
        }
        return true
    }

    /// 마지막 단계 요약(또는 기준점) 뒤의 "도구 없이 멈춤" 횟수. 요약도 기준점도 없으면 nil.
    public var idleCount: Int? {
        let counters = withPending()
        let start = [counters.idleAtSummary, counters.idleAtBaseline].compactMap { $0 }.max()
        return start.map { counters.idleTotal - $0 }
    }

    public var containsSpendLimit: Bool {
        withPending().sawSpendLimit
    }

    /// 지금까지 읽은 곳을 단계 요약처럼 취급해 그 뒤의 반복만 세게 한다("계속 기다리기").
    public mutating func markIdleBaseline() {
        committed.idleAtBaseline = withPending().idleTotal
    }

    /// 마지막 lineLimit 줄. 끝에 줄바꿈이 없으면 쓰는 중인 줄도 포함한다.
    public var tail: String {
        (lines + [Self.decodeComplete(pending)]).suffix(lineLimit).joined(separator: "\n")
    }

    private mutating func reset() {
        offset = 0
        lines = []
        pending = []
        committed = Counters()
    }

    private mutating func append(_ data: Data) {
        pending.append(contentsOf: data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return }
        // 0x0A는 UTF-8 다중 바이트 글자 안에 나오지 않으므로 줄 단위로 자르면 글자가 깨지지 않는다.
        let complete = pending[..<lastNewline]
        pending = Array(pending[(lastNewline + 1)...])
        for lineBytes in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = String(decoding: lineBytes, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            Self.scan(line, into: &committed)
            lines.append(line)
        }
        if lines.count > lineLimit * 2 {
            lines.removeFirst(lines.count - lineLimit)
        }
    }

    private func withPending() -> Counters {
        var counters = committed
        if !pending.isEmpty {
            Self.scan(Self.decodeComplete(pending), into: &counters)
        }
        return counters
    }

    private static func scan(_ line: String, into counters: inout Counters) {
        if !counters.sawSpendLimit,
           line.localizedCaseInsensitiveContains("You have reached your specified API usage limits")
            || line.localizedCaseInsensitiveContains("enforced_spend_limit_reached") {
            counters.sawSpendLimit = true
        }
        var index = line.startIndex
        while index < line.endIndex {
            let summary = line.range(of: StallDetector.summaryMarker, range: index..<line.endIndex)
            let idle = line.range(of: StallDetector.idleMarker, range: index..<line.endIndex)
            if let summary, idle.map({ summary.lowerBound < $0.lowerBound }) ?? true {
                counters.idleAtSummary = counters.idleTotal
                index = summary.upperBound
            } else if let idle {
                counters.idleTotal += 1
                index = idle.upperBound
            } else {
                break
            }
        }
    }

    /// 끝에 덜 들어온 UTF-8 글자 바이트는 빼고 디코딩한다.
    static func decodeComplete(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        var index = bytes.count - 1
        while index >= 0, index >= bytes.count - 4 {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                let width = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if bytes.count - index < width {
                    end = index
                }
                break
            }
            index -= 1
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
