import Foundation

public struct DeviceStatus: Equatable, Sendable {
    public var connected: Bool
    public var locked: Bool?
    public var wifiConnected: Bool?
    public var dndOn: Bool?
    public var notificationsAllowed: Bool?
    public var packageInstalled: Bool?

    public init(
        connected: Bool,
        locked: Bool?,
        wifiConnected: Bool?,
        dndOn: Bool?,
        notificationsAllowed: Bool?,
        packageInstalled: Bool?
    ) {
        self.connected = connected
        self.locked = locked
        self.wifiConnected = wifiConnected
        self.dndOn = dndOn
        self.notificationsAllowed = notificationsAllowed
        self.packageInstalled = packageInstalled
    }

    public var blockers: [String] {
        var blockers: [String] = []
        if !connected {
            blockers.append("기기가 연결돼 있지 않아요")
        }
        if locked == true {
            blockers.append("잠겨 있어요 — 앱이 풀 수 없어요")
        }
        if wifiConnected == false {
            blockers.append("Wi-Fi가 끊겨 있어요")
        }
        return blockers
    }

    public var warnings: [String] {
        var warnings: [String] = []
        if dndOn == true {
            warnings.append("방해 금지 모드가 켜져 있어요")
        }
        if notificationsAllowed == false {
            warnings.append("앱 알림 권한이 없어요")
        }
        return warnings
    }
}

public struct DeviceProbe: Sendable {
    private let shell: ShellRunner
    private let adbPath: String

    public init(shell: ShellRunner, adbPath: String) {
        self.shell = shell
        self.adbPath = adbPath
    }

    public func status(serial: String, package: String?) async -> DeviceStatus {
        let connected = await output(serial: serial, arguments: ["get-state"]) == "device"
        let window = await output(serial: serial, arguments: ["shell", "dumpsys", "window"])
        let wifi = Self.isEmulator(serial)
            ? nil
            : await output(serial: serial, arguments: ["shell", "cmd", "wifi", "status"])
        let zenMode = await output(
            serial: serial,
            arguments: ["shell", "settings", "get", "global", "zen_mode"]
        )

        let installed: Bool?
        if let package {
            installed = await output(
                serial: serial,
                arguments: ["shell", "pm", "path", package]
            ).map { $0.hasPrefix("package:") }
        } else {
            installed = nil
        }

        let notificationsAllowed: Bool?
        if let package, installed == true,
           let appOps = await output(
               serial: serial,
               arguments: ["shell", "cmd", "appops", "get", package, "POST_NOTIFICATION"]
           ) {
            let lowercased = appOps.lowercased()
            notificationsAllowed = !lowercased.contains("deny") && !lowercased.contains("ignore")
        } else {
            notificationsAllowed = nil
        }

        return DeviceStatus(
            connected: connected,
            locked: window.map(Self.isLocked),
            wifiConnected: wifi.map { !Self.isWifiDown($0) },
            dndOn: zenMode.flatMap(Int.init).map { $0 != 0 },
            notificationsAllowed: notificationsAllowed,
            packageInstalled: installed
        )
    }

    public func avdName(serial: String) async -> String? {
        guard Self.isEmulator(serial),
              let response = await output(serial: serial, arguments: ["emu", "avd", "name"])
        else {
            return nil
        }
        return response.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0 != "OK" }
    }

    public static func isEmulator(_ serial: String) -> Bool {
        serial.hasPrefix("emulator-")
    }

    private func output(serial: String, arguments: [String]) async -> String? {
        guard let result = try? await shell.run(adbPath, ["-s", serial] + arguments),
              result.status == 0
        else {
            return nil
        }
        let output = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static func isLocked(_ output: String) -> Bool {
        output.contains("mDreamingLockscreen=true")
            || output.contains("isKeyguardShowing=true")
            || output.contains("mShowingLockscreen=true")
    }

    private static func isWifiDown(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("Wifi is disabled")
            || output.localizedCaseInsensitiveContains("not connected")
    }
}
