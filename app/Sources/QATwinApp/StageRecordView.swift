import QATwinCore
import SwiftUI

/// 지금 돌지 않는 등록·계획 단계의 마지막 기록. 앱을 다시 띄워 끊긴 단계도 여기서 다시 시작한다.
struct StageRecordView: View {
    @Bindable var appModel: AppModel
    let stage: Stage

    @State private var isLogExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stage == .register ? "프로젝트 등록" : "테스트 계획 쓰기")
                        .font(.system(size: 22, weight: .semibold))
                    Text(statusDescription)
                        .foregroundStyle(Color.qaSecondaryText)
                        .lineSpacing(4)
                }

                statusCard

                if stage == .register, let project = appModel.selectedProject {
                    projectSummary(project)
                }

                if stage == .plan, let plan = appModel.selectedPlan {
                    planSummary(plan)
                }

                if let record, !record.log.isEmpty {
                    DisclosureGroup(isExpanded: $isLogExpanded) {
                        ScrollView(.horizontal) {
                            Text(record.log)
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
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var record: StageRecord? { appModel.viewedStageRecord }

    private var isBusy: Bool {
        appModel.activeRun != nil || appModel.activeStage != nil
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                if let record {
                    Text(timeLine(record))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.qaSecondaryText)
                }
            }
            Spacer()
            actionButton
        }
        .padding(14)
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
    }

    @ViewBuilder
    private var actionButton: some View {
        let needsRestart = record.map { [.failed, .cancelled, .interrupted].contains($0.status) } ?? false
        if stage == .plan || needsRestart, canRestart {
            Button(needsRestart ? "다시 시작" : "새 계획 쓰기", systemImage: needsRestart ? "arrow.clockwise" : "plus") {
                Task { await appModel.restartStage(from: record) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.qaButtonTint)
            .disabled(isBusy)
        }
    }

    /// 등록을 다시 하려면 기록에 소스 경로·분류가 있어야 한다.
    private var canRestart: Bool {
        guard stage == .register else { return appModel.selectedProject != nil }
        return record?.sourcePath != nil && record?.category != nil
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record?.status {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.qaPass)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.qaFail)
        case .cancelled, .interrupted:
            Image(systemName: "pause.circle.fill").foregroundStyle(Color.qaWarn)
        case .running:
            ProgressView().controlSize(.small)
        case nil:
            Image(systemName: "circle.dashed").foregroundStyle(Color.qaTertiaryText)
        }
    }

    private var statusTitle: String {
        switch record?.status {
        case .succeeded: "끝났어요"
        case .failed: "실패했어요"
        case .cancelled: "취소했어요"
        case .interrupted: "앱이 다시 시작되어 중단됐어요"
        case .running: "진행 중이에요"
        case nil: "앱에서 돌린 기록이 없어요"
        }
    }

    private var statusDescription: String {
        switch (stage, record?.status) {
        case (_, .interrupted):
            "쓰던 결과 파일은 남지 않았을 수 있어요. 다시 시작하면 처음부터 새로 해요."
        case (.register, nil):
            "앱 밖(Claude Code 등)에서 등록했거나, 단계 기록을 남기기 전에 등록했어요. 아래는 지금 등록된 정보예요."
        case (.register, _):
            "Claude Code가 앱 소스를 확인해 프로젝트를 등록한 마지막 기록이에요."
        case (_, nil):
            "앱 밖에서 썼거나 단계 기록을 남기기 전에 쓴 계획만 있어요. 새 계획을 쓰면 여기서 진행 상황을 볼 수 있어요."
        default:
            "Claude Code가 이 프로젝트의 테스트 계획을 쓴 마지막 기록이에요."
        }
    }

    private func timeLine(_ record: StageRecord) -> String {
        let start = record.startedAt.formatted(date: .abbreviated, time: .shortened)
        var parts = ["시작 \(start)"]
        if let finished = record.finishedAt {
            let seconds = Int(finished.timeIntervalSince(record.startedAt))
            parts.append(String(format: "걸린 시간 %d분 %02d초", seconds / 60, seconds % 60))
        }
        if let cost = record.cost {
            parts.append(String(format: "비용 $%.2f", cost))
        }
        return parts.joined(separator: " · ")
    }

    private func projectSummary(_ project: ProjectRef) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow("이름", project.name)
            Divider()
            summaryRow("분류", project.category == .company ? "회사" : "개인")
            Divider()
            summaryRow("소스", project.sourcePath ?? "project.local.yaml에 없음")
            Divider()
            summaryRow("계획", "\(appModel.plans(for: project).count)개")
        }
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
    }

    /// 지금 고른 계획. 계획을 확인하러 온 사람이 목록 확인으로 바로 넘어갈 수 있게 한다.
    private func planSummary(_ plan: PlanDocument) -> some View {
        let count = { (grade: Grade) in plan.scenarios.count { $0.grade == grade } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("지금 고른 계획")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.qaSecondaryText)
                Spacer()
                Button("목록 확인으로", systemImage: "list.bullet") { appModel.showStep(.review) }
                    .disabled(isBusy)
            }
            VStack(alignment: .leading, spacing: 0) {
                summaryRow("파일", plan.url.lastPathComponent)
                Divider()
                summaryRow("소스", "\(plan.header.branch) · \(plan.header.commit) · 앱 버전 \(plan.header.appVersion)")
                Divider()
                summaryRow("시나리오", "자동 \(count(.A)) · 반자동 \(count(.B)) · 수동 \(appModel.manualScenarioCount)")
            }
            .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.qaSecondaryText)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: label == "소스" ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
    }
}
