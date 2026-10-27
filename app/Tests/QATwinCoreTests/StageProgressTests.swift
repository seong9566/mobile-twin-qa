import Foundation
import Testing
@testable import QATwinCore

@Test func stageProgressReadsStartAndEndMarkers() {
    let log = """
    소스를 읽을게요.
    진행: 범위 확정 시작
    진행: 범위 확정 끝
      진행: 소스 맞추기 시작
    진행: 소스 맞추기 끝
    진행: 지식 정리 시작
    """
    let progress = StageProgress(log: log)
    #expect(progress.hasMarkers)
    #expect(progress.finished == ["범위 확정", "소스 맞추기"])
    #expect(progress.current == "지식 정리")
    #expect(!StageProgress(log: "진행 상황을 볼게요").hasMarkers)
}

@Test func stageProgressToleratesDecoration() {
    let log = """
    - 진행: 범위 확정(1절) 시작
    `진행: 범위 확정 끝`
    **진행: `소스 맞추기` 시작**
    진행: 소스 맞추기 끝.
    > 진행: 지식 정리 시작
    """
    let progress = StageProgress(log: log)
    #expect(progress.finished == ["범위 확정", "소스 맞추기"])
    #expect(progress.current == "지식 정리")
}

@Test func stageProgressReadsJudgeSteps() {
    let log = """
    진행: 실행 기록 읽기 시작
    진행: 실행 기록 읽기 끝
    진행: 시나리오 판정 시작
    """
    let progress = StageProgress(log: log, steps: StageProgress.judgeSteps)

    #expect(progress.finished == ["실행 기록 읽기"])
    #expect(progress.current == "시나리오 판정")
    #expect(progress.hasMarkers)
}

@Test func lineChangesCountsDuplicatesAndIgnoresBlank() {
    let changes = LineChanges.compare(before: "a\n\nb\nb\nc", after: "a\nb\nc\nd\n\n")
    #expect(changes.added == ["d"])
    #expect(changes.removed == ["b"])
}

@Test func planPromptAddsScopeAndAnswers() {
    let project = ProjectRef(category: .personal, name: "app", dir: URL(fileURLWithPath: "/w/personal/app"), sourcePath: nil)
    #expect(StagePrompt.plan(project: project, scope: "  ") == "앱 실행 모드: 계획\n/qa-plan\n- 프로젝트: personal/app")
    #expect(
        StagePrompt.plan(project: project, scope: "설정 탭", answers: ["플랫폼 → android"])
            == "앱 실행 모드: 계획\n/qa-plan\n- 프로젝트: personal/app\n- 범위: 설정 탭\n- 답: 플랫폼 → android"
    )
}

@Test func pilotIDsComeFromPilotSectionThenStarTitles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "QATwinPilot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func plan(_ body: String) throws -> PlanDocument {
        let url = dir.appending(path: "\(UUID().uuidString).md")
        try """
        ---
        source:
          branch: main
          commit: abc1234
          app_version: 1.0.0+1
        ---

        ## 4. 시나리오

        ### HOME-01 · 빈 홈

        - platform: android · 등급: A

        ### SCH-01 · 일정 등록 ★파일럿

        - platform: android · 등급: A

        \(body)
        """.write(to: url, atomically: true, encoding: .utf8)
        return try PlanDocument.load(url)
    }
    #expect(try plan("## 6. 파일럿\n\n1. **HOME-01** — 먼저\n2. **XYZ-99** — 없는 ID\n\n## 7. 후속 작업").pilotIDs == ["HOME-01"])
    #expect(try plan("## 7. 후속 작업").pilotIDs == ["SCH-01"])
}
