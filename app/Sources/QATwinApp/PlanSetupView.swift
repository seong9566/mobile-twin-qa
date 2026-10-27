import QATwinCore
import SwiftUI

/// 새 계획을 쓰기 전 화면: 기준 소스를 보여 주고 범위를 받은 뒤 "계획 작성하기"로 시작한다.
struct PlanSetupView: View {
    @Bindable var appModel: AppModel

    @State private var source: PlanSourceInfo?
    @State private var isLoadingSource = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("새 테스트 계획 쓰기")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Claude Code가 소스와 문서를 읽고 시나리오를 써요. 범위를 정하고 시작하면 아래 순서대로 진행 상황이 실시간으로 체크돼요.")
                        .foregroundStyle(Color.qaSecondaryText)
                        .lineSpacing(4)
                }

                section("기준 소스") { sourceCard }
                section("범위") { scopeField }
                section("진행 순서") { stepList }
                section("예상") { estimate }

                HStack {
                    Spacer()
                    Button("취소") { appModel.cancelPlanSetup() }
                        .controlSize(.large)
                    Button("계획 작성하기", systemImage: "pencil.and.list.clipboard") {
                        Task { await appModel.startPlanFromSetup() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.qaButtonTint)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(appModel.activeStage != nil || appModel.activeRun != nil)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .task(id: appModel.selectedProject?.id) {
            isLoadingSource = true
            source = nil
            if let project = appModel.selectedProject {
                source = await appModel.planSourceInfo(for: project)
            }
            isLoadingSource = false
        }
    }

    private var latestPlan: PlanDocument? {
        appModel.selectedProject.flatMap(appModel.latestPlan(for:))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
            content()
        }
    }

    @ViewBuilder
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoadingSource {
                ProgressView().controlSize(.small)
            } else if let source {
                VStack(alignment: .leading, spacing: 0) {
                    row("경로", source.path, monospaced: true)
                    Divider()
                    row("브랜치", source.branch ?? "미확인")
                    Divider()
                    row("커밋", source.commit ?? "미확인", monospaced: true)
                    Divider()
                    row("변경", source.isDirty ? "커밋하지 않은 변경이 있어요 — 그 상태 그대로 읽어요" : "없음")
                }
                .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
                if source.isCache {
                    note("받아 둔 소스(.cache)라 계획을 쓸 때 project.yaml 브랜치의 최신으로 맞춰요.", warn: false)
                }
                comparison(source)
            } else {
                note("소스 폴더를 찾지 못했어요. 계획을 쓸 때 Claude Code가 repo를 받아요.", warn: false)
            }
        }
    }

    @ViewBuilder
    private func comparison(_ source: PlanSourceInfo) -> some View {
        if let latest = latestPlan, let commit = source.commit, !source.isCache {
            let latestCommit = latest.header.commit
            if commit.hasPrefix(latestCommit) || latestCommit.hasPrefix(commit) {
                note("최근 계획(\(latest.url.lastPathComponent))과 같은 커밋이에요. 소스가 바뀌지 않았다면 다시 쓸 필요가 없을 수 있어요.", warn: false)
            } else {
                note("소스가 바뀌었어요 — 최근 계획은 \(latestCommit), 지금 소스는 \(commit) 기준이에요.", warn: true)
            }
        }
    }

    private var scopeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "예: 설정 탭과 알림만 — 비우면 최근 계획과 같은 범위(계획이 없으면 소스 전체 기능)",
                text: $appModel.planScope,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            if let latest = latestPlan {
                Text("최근 계획: \(latest.url.lastPathComponent) · 시나리오 \(latest.scenarios.count)개")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
            }
        }
    }

    private var stepList: some View {
        VStack(spacing: 0) {
            ForEach(Array(StageProgress.planSteps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.qaTertiaryText)
                        .frame(width: 16)
                    Text(step)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                if index != StageProgress.planSteps.count - 1 { Divider() }
            }
        }
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
    }

    private var estimate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("보통 5–15분 걸려요. 진행 중에도 취소할 수 있어요.")
            ClaudeRateLimitView(limits: appModel.rateLimits)
        }
        .font(.system(size: 12))
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.qaSecondaryText)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
    }

    private func note(_ text: String, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: warn ? "exclamationmark.triangle" : "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(warn ? Color.qaWarn : Color.qaSecondaryText)
    }
}
