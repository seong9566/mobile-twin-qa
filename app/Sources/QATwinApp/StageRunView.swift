import QATwinCore
import SwiftUI

struct StageRunView: View {
    @Bindable var appModel: AppModel
    let stage: Stage

    @State private var isLogExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                        Text(description)
                            .foregroundStyle(Color.qaSecondaryText)
                            .lineSpacing(4)
                    }

                    if !appModel.stageIsRunning,
                       appModel.stageWasStopped || appModel.stageFailed {
                        HStack {
                            Text(appModel.stageWasStopped ? "중지했어요" : "단계 실행에 실패했어요")
                            Spacer()
                            Button("목록으로 돌아가기") { appModel.returnFromStage() }
                        }
                    }

                    if let decision = appModel.stageDecision {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle")
                                Text(decision)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !canAnswerDecision {
                                    Button("닫기") { appModel.stageDecision = nil }
                                }
                            }
                            .foregroundStyle(Color.qaWarn)
                            // 계획 단계는 그 자리에서 답을 달아 같은 범위로 다시 쓴다.
                            if canAnswerDecision {
                                HStack(spacing: 8) {
                                    TextField("답을 적어 주세요", text: $appModel.planDecisionAnswer)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { Task { await appModel.answerPlanDecision() } }
                                    Button("답 넣고 다시 시작", systemImage: "arrow.clockwise") {
                                        Task { await appModel.answerPlanDecision() }
                                    }
                                    .disabled(appModel.planDecisionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.qaWarnWeak, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaWarnLine))
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                            HStack(spacing: 12) {
                                taskIcon(index)
                                    .frame(width: 16, height: 16)
                                Text(task)
                                    .fontWeight(index == currentTaskIndex ? .semibold : .regular)
                                    .foregroundStyle(index > currentTaskIndex ? Color.qaTertiaryText : Color.qaText)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            if index != tasks.indices.last { Divider() }
                        }
                    }
                    .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))

                    if appModel.stageIsRunning, appModel.activeStage == stage {
                        HStack {
                            Text("취소하면 Claude Code를 멈춰요. 쓰다 만 파일이 남았으면 확인해 주세요.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.qaSecondaryText)
                            Spacer()
                            Button("취소", systemImage: "xmark", role: .destructive) {
                                appModel.confirmStageCancel()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }

                    DisclosureGroup(isExpanded: $isLogExpanded) {
                        ScrollView(.horizontal) {
                            Text(appModel.stageLog.isEmpty ? "출력을 기다리고 있어요." : appModel.stageLog)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(Color.qaBar.opacity(0.55))
                    } label: {
                        Text("Claude Code 출력 원문")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.qaSecondaryText)
                    }
                    .padding(12)
                    .background(Color.qaSunken, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 32)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack(spacing: 14) {
                if appModel.stageIsRunning {
                    ProgressView().controlSize(.mini)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Claude Code 실행 중 · \(elapsed(at: context.date))")
                    }
                } else {
                    Text("Claude Code 단계 종료")
                }
                Divider().frame(height: 12)
                Text(String(format: "Claude 단계 비용 $%.2f", appModel.stageCost ?? 0))
                Divider().frame(height: 12)
                Text("취소하면 쓰다 만 파일이 남았는지 확인해 주세요")
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.qaSecondaryText)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Color.qaBar)
        }
    }

    private var title: String {
        switch stage {
        case .register: "프로젝트를 등록하고 있어요"
        case .plan: "테스트 계획을 쓰고 있어요"
        case .prepare: "실행을 준비하고 있어요"
        case .judge: "결과를 판정하고 있어요"
        }
    }

    private var description: String {
        switch stage {
        case .register:
            "Claude Code가 앱 소스와 프로젝트 정보를 확인해 등록해요. 끝나면 새 계획의 범위를 정하는 화면으로 가요."
        case .plan:
            "Claude Code가 소스와 문서를 읽고 시나리오를 써요. 아래 항목은 실제 진행에 맞춰 체크되고, 끝나면 요약을 보여 드려요. 보통 5–15분 걸려요."
        case .prepare:
            "Claude Code가 승인한 기기·서버·시나리오로 실행 폴더를 준비해요."
        case .judge:
            "Claude Code가 실행 기록을 읽고 결과를 판정해요. 아래 항목은 실제 진행에 맞춰 체크돼요."
        }
    }

    private var canAnswerDecision: Bool {
        stage == .plan && !appModel.stageIsRunning && appModel.activeStage == nil
    }

    /// 스킬이 낸 진행 줄. 계획·판정 단계가 낸다.
    private var progress: StageProgress? {
        guard stage == .plan || stage == .judge else { return nil }
        let progress = stage == .judge
            ? StageProgress(log: appModel.stageLog, steps: StageProgress.judgeSteps)
            : StageProgress(log: appModel.stageLog)
        return progress.hasMarkers ? progress : nil
    }

    /// 성공으로 끝났는지. 중지·실패·결정 필요로 멈췄으면 끝낸 항목까지만 체크한다.
    private var finishedCleanly: Bool {
        !appModel.stageIsRunning && !appModel.stageWasStopped && !appModel.stageFailed && appModel.stageDecision == nil
    }

    private var tasks: [String] {
        switch stage {
        case .register: ["소스 확인", "프로젝트 등록", "설정 저장"]
        case .plan: StageProgress.planSteps
        case .prepare: ["승인 내용 확인", "실행 폴더 만들기", "실행 준비"]
        case .judge: StageProgress.judgeSteps
        }
    }

    /// 지금(또는 멈춘) 항목. 진행 줄이 있으면 그것을, 없으면 출력 양으로 어림한다.
    private var currentTaskIndex: Int {
        if finishedCleanly { return tasks.count }
        if let progress {
            if let current = progress.current, let index = tasks.firstIndex(of: current) { return index }
            return tasks.firstIndex { !progress.finished.contains($0) } ?? tasks.count
        }
        let lines = appModel.stageLog.components(separatedBy: .newlines).count
        return min(max(lines / 8, 0), max(tasks.count - 1, 0))
    }

    private func isTaskDone(_ index: Int) -> Bool {
        if finishedCleanly { return true }
        if let progress { return progress.finished.contains(tasks[index]) }
        return index < currentTaskIndex
    }

    @ViewBuilder
    private func taskIcon(_ index: Int) -> some View {
        if isTaskDone(index) {
            Image(systemName: "checkmark")
                .foregroundStyle(Color.qaPass)
                .fontWeight(.bold)
        } else if index == currentTaskIndex, appModel.stageIsRunning {
            ProgressView().controlSize(.small)
        } else if index == currentTaskIndex {
            // 중지·실패·결정 필요로 여기서 멈췄다.
            Image(systemName: appModel.stageDecision != nil ? "questionmark.circle" : appModel.stageFailed ? "xmark.circle" : "pause.circle")
                .foregroundStyle(appModel.stageFailed ? Color.qaFail : Color.qaWarn)
        } else {
            Circle().stroke(Color.qaStrongLine, lineWidth: 1.5)
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(appModel.stageStartedAt ?? date))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

