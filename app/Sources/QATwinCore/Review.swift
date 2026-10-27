import Foundation

public struct ReviewEntry: Codable, Equatable {
    public var memo: String
    public var causeOverride: Cause?
    public var include: Bool

    public init(memo: String, causeOverride: Cause?, include: Bool) {
        self.memo = memo
        self.causeOverride = causeOverride
        self.include = include
    }
}

public struct Review: Codable {
    public var entries: [String: ReviewEntry]

    public init(entries: [String: ReviewEntry] = [:]) {
        self.entries = entries
    }

    public static func load(runDir: URL) -> Review {
        let url = runDir.appending(path: "review.json")
        guard let data = try? Data(contentsOf: url),
              let review = try? JSONDecoder().decode(Review.self, from: data)
        else {
            return Review()
        }
        return review
    }

    public func save(runDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: runDir.appending(path: "review.json"), options: .atomic)
    }

    public func entry(for result: ScenarioResult) -> ReviewEntry {
        if let entry = entries[result.id] {
            return entry
        }

        let resultCause = result.cause?.rawValue ?? result.rawCause
        return ReviewEntry(
            memo: "",
            causeOverride: nil,
            include: (result.outcome == .fail || result.outcome == .hold)
                && resultCause != Cause.toolMisjudgment.rawValue
        )
    }

    /// 원인을 바로잡는다. nil이나 Claude 판정과 같은 값이면 바로잡지 않은 것으로 되돌린다.
    /// md 포함 여부도 그 원인 기준으로 다시 정한다 — 기본 규칙(entry(for:))처럼 실패·보류만 넣고 도구 오판이면 뺀다.
    public mutating func correctCause(_ cause: Cause?, for result: ScenarioResult) {
        var entry = entry(for: result)
        entry.causeOverride = cause == result.cause ? nil : cause
        let needsAttention = result.outcome == .fail || result.outcome == .hold
        entry.include = needsAttention && (cause ?? result.cause) != .toolMisjudgment
        entries[result.id] = entry
    }
}
