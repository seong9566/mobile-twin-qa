import CryptoKit
import Foundation

public enum SecretKeys {
    public static func isSecret(_ key: String, accountKeys: Set<String>) -> Bool {
        if accountKeys.contains(key) {
            return true
        }
        let uppercased = key.uppercased()
        return ["KEY", "SECRET", "TOKEN", "PASS", "PW"].contains { uppercased.contains($0) }
    }

    public static func values(envURL: URL, accountKeys: Set<String>) -> [String] {
        EnvFile(url: envURL).entriesInOrder().compactMap { entry in
            guard !entry.value.isEmpty, isSecret(entry.key, accountKeys: accountKeys) else {
                return nil
            }
            return entry.value
        }
    }
}

public struct BuildEnv: Equatable, Sendable {
    public let contents: String
    public let sha256: String

    public static func make(
        envURL: URL,
        accountKeys: Set<String>,
        server: ServerConfig,
        macIP: String
    ) -> BuildEnv {
        var lines: [String] = []
        var remainingVars = server.vars

        for entry in EnvFile(url: envURL).entriesInOrder() where !accountKeys.contains(entry.key) {
            let value = remainingVars.removeValue(forKey: entry.key) ?? entry.value
            lines.append("\(entry.key)=\(replacingMacIP(in: value, with: macIP))")
        }
        for key in remainingVars.keys.sorted() where !accountKeys.contains(key) {
            let value = remainingVars[key] ?? ""
            lines.append("\(key)=\(replacingMacIP(in: value, with: macIP))")
        }

        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(contents.utf8))
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()
        return BuildEnv(contents: contents, sha256: sha256)
    }

    public func write(to dir: URL) throws -> URL {
        let url = dir.appending(path: "qa-app-\(UUID().uuidString).env")
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func replacingMacIP(in value: String, with macIP: String) -> String {
        value.replacingOccurrences(of: "{{mac_ip}}", with: macIP)
    }
}

public enum MacIP {
    public static func current(shell: ShellRunner) async -> String? {
        guard let route = try? await shell.run("/sbin/route", ["-n", "get", "default"]),
              route.status == 0,
              let interface = route.out.components(separatedBy: .newlines).compactMap({ line in
                  let parts = line.split(separator: ":", maxSplits: 1).map {
                      $0.trimmingCharacters(in: .whitespaces)
                  }
                  return parts.count == 2 && parts[0] == "interface" ? parts[1] : nil
              }).first,
              !interface.isEmpty,
              let address = try? await shell.run("/usr/sbin/ipconfig", ["getifaddr", interface]),
              address.status == 0
        else {
            return nil
        }
        return address.out.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
