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
}
