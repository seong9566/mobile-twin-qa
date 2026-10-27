import Testing
@testable import QATwinCore

@Suite struct DeviceProbeTests {
    @Test func deviceProbeReadsLockedAndWifi() async {
        let shell = RecordingShell(responses: [
            ("get-state", 0, "device\n"),
            ("dumpsys window", 0, "mDreamingLockscreen=true\n"),
            ("cmd wifi status", 0, "Wifi is enabled\nWifi is not connected\n"),
        ])
        let probe = DeviceProbe(shell: shell, adbPath: "/test/adb")

        let status = await probe.status(serial: "DEVICE1", package: nil)

        #expect(status.connected)
        #expect(status.locked == true)
        #expect(status.wifiConnected == false)
        #expect(status.blockers == [
            "잠겨 있어요 — 앱이 풀 수 없어요",
            "Wi-Fi가 끊겨 있어요",
        ])
    }

    @Test func deviceProbeSkipsWifiOnEmulator() async {
        let shell = RecordingShell(responses: [
            ("get-state", 0, "device\n"),
            ("dumpsys window", 0, "mDreamingLockscreen=false\n"),
        ])
        let probe = DeviceProbe(shell: shell, adbPath: "/test/adb")

        let status = await probe.status(serial: "emulator-5554", package: nil)

        #expect(status.wifiConnected == nil)
        #expect(!shell.calls.contains { $0.args.contains("wifi") })
    }

    @Test func deviceProbeUnknownIsNotBlocker() async {
        let shell = RecordingShell()
        let probe = DeviceProbe(shell: shell, adbPath: "/test/adb")

        let status = await probe.status(serial: "DEVICE1", package: "com.example.app")

        #expect(!status.connected)
        #expect(status.locked == nil)
        #expect(status.wifiConnected == nil)
        #expect(status.dndOn == nil)
        #expect(status.notificationsAllowed == nil)
        #expect(status.packageInstalled == nil)
        #expect(status.blockers == ["기기가 연결돼 있지 않아요"])
        #expect(status.warnings.isEmpty)
    }
}
