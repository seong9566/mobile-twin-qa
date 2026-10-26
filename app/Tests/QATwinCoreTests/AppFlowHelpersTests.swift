import Foundation
import Testing
@testable import QATwinCore

private func helperTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreAppFlowHelpersTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func deviceChoicesKeepOnlyIdleConnectedDevices() {
    let devices = [
        ArtemisDevice(serial: "A", state: "device", model: "Pixel", is_busy: false),
        ArtemisDevice(serial: "B", state: "device", model: nil, is_busy: true),
        ArtemisDevice(serial: "C", state: "unauthorized", model: nil, is_busy: nil),
        ArtemisDevice(serial: "D", state: "offline", model: nil, is_busy: false),
        ArtemisDevice(serial: "E", state: "device", model: nil, is_busy: nil),
    ]
    let choices = ArtemisDevice.choices(from: devices)
    #expect(choices.usable.map(\.serial) == ["A", "E"])
    #expect(choices.busyCount == 1)
    #expect(choices.unavailableCount == 2)
}

@Test func gitHeadParsesBranchAndDetached() {
    #expect(GitHead(revParseOutput: "main\n") == .branch("main"))
    #expect(GitHead(revParseOutput: "main\n").isMain)
    #expect(!GitHead(revParseOutput: "fix/x\n").isMain)
    #expect(GitHead(revParseOutput: "HEAD\n") == .detached)
    #expect(!GitHead(revParseOutput: "HEAD").isMain)
}

@Test func resolvePlanAcceptsRelativePathAndLegacyFileName() throws {
    let root = try helperTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appending(path: "personal/demo")
    let plans = projectDir.appending(path: "plans")
    try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
    let plan = plans.appending(path: "2026-01-02-demo_test_plan.md")
    try "# plan".write(to: plan, atomically: true, encoding: .utf8)
    let workspace = Workspace(root: root)

    #expect(
        workspace.resolvePlan("personal/demo/plans/2026-01-02-demo_test_plan.md", projectDir: projectDir)?
            .standardizedFileURL == plan.standardizedFileURL
    )
    #expect(
        workspace.resolvePlan("2026-01-02-demo_test_plan.md", projectDir: projectDir)?
            .standardizedFileURL == plan.standardizedFileURL
    )
    #expect(workspace.resolvePlan(plan.path, projectDir: projectDir) != nil)
    #expect(workspace.resolvePlan("2026-09-09-missing.md", projectDir: projectDir) == nil)
    #expect(workspace.resolvePlan("personal/demo/plans/missing.md", projectDir: projectDir) == nil)
}

@Test func accountEnvKeysReadsFlowAndBlockStyles() {
    let yaml = """
    app_id: demo
    accounts:                     # 역할 → .env 키 이름
      # ignored: { id_env: COMMENTED_ID, password_env: COMMENTED_PW }
      field_worker: { id_env: TEST_USER_ID, password_env: TEST_USER_PASSWORD }
      admin:
        id_env: "ADMIN_ID"
        password_env: ADMIN_PASSWORD
    environments:
      dev: { id_env: NOT_ACCOUNT }
    """
    #expect(
        Workspace.accountEnvKeys(projectYAML: yaml)
            == ["TEST_USER_ID", "TEST_USER_PASSWORD", "ADMIN_ID", "ADMIN_PASSWORD"]
    )
    #expect(Workspace.accountEnvKeys(projectYAML: "accounts: {}   # 없음\n").isEmpty)
    #expect(Workspace.accountEnvKeys(projectYAML: "app_id: x\n").isEmpty)
}

@Test func removeRunDirectoryOnlyWhenEmpty() throws {
    let root = try helperTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appending(path: "empty")
    let withFile = root.appending(path: "withFile")
    let withHidden = root.appending(path: "withHidden")
    let withFolder = root.appending(path: "withFolder")
    for url in [empty, withFile, withHidden, withFolder] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try "x".write(to: withFile.appending(path: "run-state.json"), atomically: true, encoding: .utf8)
    try "x".write(to: withHidden.appending(path: ".keep"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: withFolder.appending(path: "artifacts"), withIntermediateDirectories: true)

    #expect(Workspace.removeRunDirectoryIfEmpty(empty))
    #expect(!FileManager.default.fileExists(atPath: empty.path))
    for url in [withFile, withHidden, withFolder] {
        #expect(!Workspace.removeRunDirectoryIfEmpty(url))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    #expect(!Workspace.removeRunDirectoryIfEmpty(root.appending(path: "missing")))
}
