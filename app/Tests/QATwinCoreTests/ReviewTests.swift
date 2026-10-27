import Testing
@testable import QATwinCore

private func result(_ outcome: Outcome, _ cause: Cause?) -> ScenarioResult {
    ScenarioResult(
        id: "HOME-01", title: nil, outcome: outcome, rawOutcome: nil, cause: cause, rawCause: cause?.rawValue,
        expected: nil, actual: nil, reason: nil, evidence: []
    )
}

@Test func correctingCauseToToolMisjudgmentExcludesFromFixRequest() {
    var review = Review()
    review.correctCause(.toolMisjudgment, for: result(.fail, .appDefect))
    #expect(review.entries["HOME-01"] == ReviewEntry(memo: "", causeOverride: .toolMisjudgment, include: false))
}

@Test func correctingCauseAwayFromToolMisjudgmentIncludesAgain() {
    var review = Review()
    review.correctCause(.appDefect, for: result(.hold, .toolMisjudgment))
    #expect(review.entries["HOME-01"] == ReviewEntry(memo: "", causeOverride: .appDefect, include: true))
}

@Test func correctingCauseToClaudeVerdictOrNilClearsOverride() {
    var review = Review()
    let failed = result(.fail, .toolMisjudgment)
    review.correctCause(.appDefect, for: failed)
    review.correctCause(.toolMisjudgment, for: failed)
    #expect(review.entries["HOME-01"]?.causeOverride == nil)
    #expect(review.entries["HOME-01"]?.include == false)
    review.correctCause(.environment, for: failed)
    review.correctCause(nil, for: failed)
    #expect(review.entries["HOME-01"] == ReviewEntry(memo: "", causeOverride: nil, include: false))
}

@Test func correctingCauseKeepsMemoAndNeverIncludesPassed() {
    var review = Review(entries: ["HOME-01": ReviewEntry(memo: "메모", causeOverride: nil, include: false)])
    review.correctCause(.appDefect, for: result(.pass, nil))
    #expect(review.entries["HOME-01"] == ReviewEntry(memo: "메모", causeOverride: .appDefect, include: false))
}
