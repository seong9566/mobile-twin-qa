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
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                            Text(decision)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("닫기") { appModel.stageDecision = nil }
                        }
                        .foregroundStyle(Color.qaWarn)
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
                Text("중지하면 쓰던 결과 파일은 남기지 않아요")
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
            "Claude Code가 앱 소스와 프로젝트 정보를 확인해 등록해요. 끝나면 테스트 계획을 써요."
        case .plan:
            "Claude Code가 소스와 문서를 읽고 시나리오를 써요. 끝나면 목록 확인으로 넘어가요. 보통 5–15분 걸려요."
        case .prepare:
            "Claude Code가 승인한 기기·서버·시나리오로 실행 폴더를 준비해요."
        case .judge:
            "Claude Code가 실행 기록을 읽고 결과를 판정해요."
        }
    }

    private var tasks: [String] {
        switch stage {
        case .register: ["소스 확인", "프로젝트 등록", "설정 저장"]
        case .plan: ["소스 맞추기", "지식 정리", "화면 분석", "시나리오 쓰기", "계획 저장"]
        case .prepare: ["승인 내용 확인", "실행 폴더 만들기", "실행 준비"]
        case .judge: ["실행 기록 읽기", "시나리오 판정", "결과 저장"]
        }
    }

    private var currentTaskIndex: Int {
        guard appModel.stageIsRunning else { return max(tasks.count - 1, 0) }
        let progress = appModel.stageLog.components(separatedBy: .newlines).count
        return min(max(progress / 8, 0), max(tasks.count - 1, 0))
    }

    @ViewBuilder
    private func taskIcon(_ index: Int) -> some View {
        if index < currentTaskIndex || !appModel.stageIsRunning {
            Image(systemName: "checkmark")
                .foregroundStyle(Color.qaPass)
                .fontWeight(.bold)
        } else if index == currentTaskIndex {
            ProgressView().controlSize(.small)
        } else {
            Circle().stroke(Color.qaStrongLine, lineWidth: 1.5)
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(appModel.stageStartedAt ?? date))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

