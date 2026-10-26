import Foundation
import Testing
@testable import QATwinCore

private let demo = ProjectRef(
    category: .personal,
    name: "demo_app",
    dir: URL(fileURLWithPath: "/tmp/demo_app"),
    sourcePath: nil
)

private func claudeRunnerTempDir() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreClaudeRunnerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func parsesAssistantTextToolAndResult() {
    #expect(
        StreamJSONParser.parse(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"빌드 중"},{"type":"tool_use","name":"Bash"}]}}"#
        ) == [.text("빌드 중"), .tool("Bash")]
    )
    #expect(
        StreamJSONParser.parse(
            line: #"{"type":"result","is_error":false,"total_cost_usd":0.42,"result":"끝"}"#
        ) == [.result(isError: false, costUSD: 0.42, summary: "끝")]
    )
    #expect(StreamJSONParser.parse(line: "not json").isEmpty)
}

@Test func promptsStartWithModeAndCarryNoSecrets() {
    #expect(
        StagePrompt.register(sourcePath: "/tmp/demo", category: .personal)
            == "앱 실행 모드: 등록\n/qa-init\n- 소스 경로: /tmp/demo\n- 분류: personal"
    )
    #expect(
        StagePrompt.plan(project: demo, scope: "로그인")
            == "앱 실행 모드: 계획\n/qa-plan\n- 프로젝트: personal/demo_app\n- 범위: 로그인"
    )

    let prompt = StagePrompt.prepare(
        project: demo,
        plan: "personal/demo_app/plans/a.md",
        runDir: "personal/demo_app/runs/a/2026-01-03-0900",
        deviceSerial: "D1",
        server: "dev",
        scenarioIDs: ["HOME-01", "HOME-02"],
        buildInstall: true,
        screenshotApproved: true
    )
    #expect(
        prompt == """
        앱 실행 모드: 준비
        /qa-run
        - 프로젝트: personal/demo_app
        - 계획: personal/demo_app/plans/a.md
        - 실행 폴더: personal/demo_app/runs/a/2026-01-03-0900
        - 기기: D1
        - 서버: dev
        - 시나리오: HOME-01, HOME-02
        - 빌드·설치: 예
        - 스크린샷 전송 승인: 해당 없음(개인)
        """
    )
    #expect(
        StagePrompt.judge(
            project: demo,
            plan: "personal/demo_app/plans/a.md",
            runDir: "personal/demo_app/runs/a/2026-01-03-0900"
        ) == "앱 실행 모드: 판정\n/qa-run\n- 프로젝트: personal/demo_app\n- 계획: personal/demo_app/plans/a.md\n- 실행 폴더: personal/demo_app/runs/a/2026-01-03-0900"
    )
}

@Test func rateLimitsParse() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let limits = ClaudeRateLimits.parse(
        "3 1793005800 29 1793296800",
        updatedAt: now,
        now: now
    )
    #expect(limits?.fiveHourPct == 3 && limits?.sevenDayPct == 29)
    #expect(
        ClaudeRateLimits.parse(
            "3 1792000000 - -",
            updatedAt: now,
            now: now
        )?.fiveHourPct == nil
    )
    #expect(ClaudeRateLimits.parse("garbage", updatedAt: now, now: now) == nil)
}

@Test func cancelTerminatesProcess() async throws {
    let directory = try claudeRunnerTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appending(path: "slow-claude.sh")
    try "#!/bin/sh\nsleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let runner = ClaudeRunner(executable: executable, workspaceRoot: directory)
    let stream = runner.run(prompt: "test")
    let consumer = Task {
        do {
            for try await _ in stream {}
        } catch {}
    }

    try await Task.sleep(for: .milliseconds(100))
    let cancelledAt = Date()
    runner.cancel()
    await consumer.value

    #expect(Date().timeIntervalSince(cancelledAt) < 5)
}

@Test func parsesRateLimitEvent() {
    let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.22,"resetsAt":1793005800,"status":"allowed"},"seven_day":{"utilization":0.31,"resetsAt":1793296800,"status":"allowed"}}}}"#
    guard case let .rateLimits(limits)? = StreamJSONParser.parse(line: line).first else {
        Issue.record("rate limit event not parsed")
        return
    }
    #expect(limits.fiveHourPct == 22 && limits.sevenDayPct == 31)
    #expect(limits.fiveHourResetsAt == Date(timeIntervalSince1970: 1_793_005_800))
}
