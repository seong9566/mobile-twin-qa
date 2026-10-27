import Foundation
import Testing
@testable import QATwinCore

@Suite struct InstallRecordTests {
    @Test func buildSkipDecidesInOrder() {
        let entry = InstallEntry(
            package: "com.example.app",
            commit: "installed",
            dirty: true,
            envSHA256: "old-env",
            at: Date(timeIntervalSince1970: 1_000)
        )

        #expect(BuildSkip.decide(
            entry: nil, headCommit: "source", sourceDirty: true, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "이 기기에 설치한 기록이 없어요"))
        #expect(BuildSkip.decide(
            entry: entry, headCommit: "source", sourceDirty: true, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "설치본이 커밋하지 않은 변경으로 빌드됐어요"))

        var matchingEntry = entry
        matchingEntry.dirty = false
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: true, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "소스에 커밋하지 않은 변경이 있어요"))
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: false, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "설치본 installed ≠ 소스 source"))

        matchingEntry.commit = "source"
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: false, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "서버 설정이 바뀌었어요"))

        matchingEntry.envSHA256 = "new-env"
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: false, envSHA256: "new-env",
            packageInstalled: false, forceRebuild: true
        ) == .build(reason: "기기에 앱이 없어요"))
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: false, envSHA256: "new-env",
            packageInstalled: true, forceRebuild: true
        ) == .build(reason: "다시 빌드를 골랐어요"))
        #expect(BuildSkip.decide(
            entry: matchingEntry, headCommit: "source", sourceDirty: false, envSHA256: "new-env",
            packageInstalled: true, forceRebuild: false
        ) == .skip)
    }

    @Test func installRecordsKeepOtherSerials() throws {
        let projectDir = try tempDir("InstallRecordTests")
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let first = InstallEntry(
            package: "com.example.first", commit: "aaa", dirty: false,
            envSHA256: "env-a", at: Date(timeIntervalSince1970: 1_000)
        )
        let second = InstallEntry(
            package: "com.example.second", commit: "bbb", dirty: true,
            envSHA256: "env-b", at: Date(timeIntervalSince1970: 2_000)
        )

        try InstallRecords.save(first, serial: "A", projectDir: projectDir)
        try InstallRecords.save(second, serial: "B", projectDir: projectDir)

        let records = InstallRecords.load(projectDir: projectDir)
        #expect(records == ["A": first, "B": second])
        let json = try String(contentsOf: projectDir.appending(path: ".install.json"), encoding: .utf8)
        #expect(json.contains("\"env_sha256\""))
        #expect(!json.contains("\"envSHA256\""))
    }
}
