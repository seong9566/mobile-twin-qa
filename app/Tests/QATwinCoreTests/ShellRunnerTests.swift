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
