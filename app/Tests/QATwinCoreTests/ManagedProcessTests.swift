import Darwin
import Foundation
import Testing
@testable import QATwinCore

@Suite struct ManagedProcessTests {
    @Test func loginShellCommandQuotesValues() {
        let command = LoginShell.command(
            "cd \"$ARTEMIS_HOME\" && ls",
            exports: [("ARTEMIS_HOME", "/a b/it's")]
        )

        #expect(command == "export ARTEMIS_HOME='/a b/it'\\''s'; cd \"$ARTEMIS_HOME\" && ls")
    }

    @Test func managedProcessReportsEarlyExit() async throws {
        let process = ManagedProcess(
            exe: "/bin/sh",
            args: ["-c", "echo boom; exit 3"],
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            logURL: nil
        )

        try process.start()
        let exited = await waitUntil(timeout: 1) { !process.isRunning }

        #expect(exited)
        #expect(process.exitStatus == 3)
        #expect(process.tail(lines: 5).contains("boom"))
    }

    @Test func terminateKillsGroup() async throws {
        let process = ManagedProcess(
            exe: "/bin/sh",
            args: ["-c", "echo $$; sleep 30 & sleep 30"],
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            logURL: nil
        )

        try process.start()
        let reportedPID = await waitUntil(timeout: 1) { !process.tail(lines: 1).isEmpty }
        #expect(reportedPID)
        let groupID = try #require(
            Int32(process.tail(lines: 1).trimmingCharacters(in: .whitespacesAndNewlines))
        )

        await process.terminate()

        #expect(Darwin.kill(-groupID, 0) != 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@Test func trackingLauncherFindsRunningProcessByCommand() async throws {
    let launcher = TrackingProcessLauncher()
    let process = try launcher.launch(
        exe: "/bin/sh",
        args: ["-c", "sleep 5 # uv run artemis ui --port 8100"],
        cwd: FileManager.default.temporaryDirectory,
        logURL: nil
    )

    #expect(launcher.running(matching: "artemis ui") === process)
    #expect(launcher.running(matching: "server/run.sh") == nil)
    #expect(launcher.processes.count == 1)

    await process.terminate()
    try await Task.sleep(for: .milliseconds(200))
    #expect(launcher.running(matching: "artemis ui") == nil)
    launcher.forget(process)
    #expect(launcher.processes.isEmpty)
}
