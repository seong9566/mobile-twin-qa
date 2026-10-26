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
