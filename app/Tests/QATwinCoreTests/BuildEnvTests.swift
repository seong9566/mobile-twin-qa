import Foundation
import Testing
@testable import QATwinCore

@Suite struct BuildEnvTests {
    @Test func secretKeysMatchAccountsAndNames() {
        #expect(SecretKeys.isSecret("TEST_USER_ID", accountKeys: ["TEST_USER_ID"]))
        #expect(SecretKeys.isSecret("naver_secret", accountKeys: []))
        #expect(SecretKeys.isSecret("API_KEY", accountKeys: []))
        #expect(SecretKeys.isSecret("DB_PW", accountKeys: []))
        #expect(!SecretKeys.isSecret("API_BASE_URL", accountKeys: []))
    }

    @Test func buildEnvExcludesAccountsAndAppliesVars() throws {
        let directory = try tempDir()
        let envURL = directory.appending(path: ".env")
        try "TEST_USER_ID=u\nAPI_BASE_URL=http://old\nMAP_ID=\"m\"\n"
            .write(to: envURL, atomically: true, encoding: .utf8)
        let server = ServerConfig(
            name: "local",
            health: nil,
            start: nil,
            cwd: ".",
            startTimeout: 60,
            vars: ["API_BASE_URL": "http://{{mac_ip}}:5199"]
        )

        let buildEnv = BuildEnv.make(
            envURL: envURL,
            accountKeys: ["TEST_USER_ID"],
            server: server,
            macIP: "192.168.0.12"
        )

        #expect(buildEnv.contents == "API_BASE_URL=http://192.168.0.12:5199\nMAP_ID=m\n")
    }

    @Test func buildEnvIsStableAndUsesFirstOccurrence() throws {
        let directory = try tempDir()
        let envURL = directory.appending(path: ".env")
        try "A=1\nA=2\n".write(to: envURL, atomically: true, encoding: .utf8)
        let server = ServerConfig(
            name: "local",
            health: nil,
            start: nil,
            cwd: ".",
            startTimeout: 60,
            vars: [:]
        )

        let first = BuildEnv.make(envURL: envURL, accountKeys: [], server: server, macIP: "127.0.0.1")
        let second = BuildEnv.make(envURL: envURL, accountKeys: [], server: server, macIP: "127.0.0.1")

        #expect(first.contents == "A=1\n")
        #expect(first.sha256 == second.sha256)
    }

    @Test func buildEnvFileIsPrivate() throws {
        let directory = try tempDir()
        let server = ServerConfig(
            name: "local",
            health: nil,
            start: nil,
            cwd: ".",
            startTimeout: 60,
            vars: [:]
        )
        let buildEnv = BuildEnv.make(
            envURL: directory.appending(path: ".env"),
            accountKeys: [],
            server: server,
            macIP: "127.0.0.1"
        )

        let url = try buildEnv.write(to: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
