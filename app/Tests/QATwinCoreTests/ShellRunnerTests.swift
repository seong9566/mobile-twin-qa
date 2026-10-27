import Foundation
import Testing
@testable import QATwinCore

@Test func shellRunnerReturnsOutput() async throws {
    let result = try await ProcessShellRunner().run("/bin/echo", ["hi"])
    #expect(result.status == 0)
    #expect(result.out == "hi\n")
}

@Test func shellRunnerTimesOut() async throws {
    let startedAt = Date()
    await #expect(throws: ShellRunnerError.timedOut) {
        _ = try await ProcessShellRunner().run("/bin/sleep", ["5"], timeout: .milliseconds(300))
    }
    #expect(Date().timeIntervalSince(startedAt) < 3)
}

@Test func shellRunnerReturnsWhenGrandchildHoldsPipe() async throws {
    let startedAt = Date()
    let result = try await ProcessShellRunner().run(
        "/bin/sh",
        ["-c", "sleep 3 & echo hi"],
        timeout: .milliseconds(300)
    )
    #expect(result.status == 0)
    #expect(result.out == "hi\n")
    #expect(Date().timeIntervalSince(startedAt) < 2)
}

@Test func shellRunnerCancelKillsProcessGroup() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: "shell-cancel-\(UUID().uuidString)")
    // 2초 뒤 파일을 만드는 자식. 취소로 그룹이 끝나면 파일이 생기지 않는다.
    let task = Task {
        try await ProcessShellRunner().run("/bin/sh", ["-c", "sleep 2 && touch '\(marker.path)'"], timeout: .seconds(20))
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    let started = Date()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 1.5)
    try await Task.sleep(for: .seconds(2.5))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func shellRunnerCancelledBeforeStartLaunchesNothing() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: "shell-precancel-\(UUID().uuidString)")
    let task = Task {
        // 실행하기 전에 스스로 취소한다 — 프로세스를 띄우지 않고 취소로 끝나야 한다(앱 자신에게 신호도 없다).
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProcessShellRunner().run("/bin/sh", ["-c", "touch '\(marker.path)'"], timeout: .seconds(5))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
