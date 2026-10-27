import Foundation
import Testing
@testable import QATwinCore

private func store() throws -> StageRecordStore {
    let dir = FileManager.default.temporaryDirectory.appending(path: "QATwinStageRecords-\(UUID().uuidString)")
    return StageRecordStore(dir: dir)
}

@Test func stageRecordRoundTripsAndRunningBecomesInterruptedWhenNotLive() throws {
    let store = try store()
    defer { try? FileManager.default.removeItem(at: store.dir) }
    let record = StageRecord(
        stage: .plan, key: "personal/departure-assistant", startedAt: Date(timeIntervalSince1970: 1_000),
        status: .running, log: "쓰는 중"
    )
    try store.save(record)
    #expect(store.load(stage: .plan, key: "personal/departure-assistant", isLive: true) == record)
    #expect(store.load(stage: .plan, key: "personal/departure-assistant", isLive: false)?.status == .interrupted)
    #expect(store.load(stage: .register, key: "personal/departure-assistant", isLive: false) == nil)
}

@Test func stageRecordKeepsLogTail() throws {
    let store = try store()
    defer { try? FileManager.default.removeItem(at: store.dir) }
    let log = String(repeating: "a", count: StageRecordStore.logLimit) + "끝"
    try store.save(StageRecord(stage: .register, key: "app", startedAt: .now, status: .succeeded, log: log))
    let loaded = try #require(store.load(stage: .register, key: "app", isLive: false))
    #expect(loaded.log.count == StageRecordStore.logLimit)
    #expect(loaded.log.hasSuffix("a끝"))
}
