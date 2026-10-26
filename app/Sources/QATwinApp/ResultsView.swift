import AppKit
import Foundation
import QATwinCore
import SwiftUI
import UniformTypeIdentifiers

struct ResultsView: View {
    @Bindable var appModel: AppModel
    let runDir: URL

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            HStack(spacing: 0) {
                resultList
                    .frame(width: 300)
                Divider()
                if let selectedResult {
                    ResultCard(appModel: appModel, result: selectedResult, runDir: runDir)
                } else {
                    ContentUnavailableView("결과 없음", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            statusBar
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("\(totals.total)개 중 \(totals.pass)개 통과")
                    .font(.system(size: 17, weight: .semibold))
                summaryLabel("실패 \(totals.fail)", color: .qaFail)
                summaryLabel("보류 \(totals.hold)", color: .qaHold)
                summaryLabel("미실행 \(totals.notRun)", color: .qaTertiaryText)
                Spacer()
                Text("칸을 누르면 그 시나리오로 가요")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaSecondaryText)
            }
            RunTapeView(cells: tapeCells) { appModel.selectedResultID = $0 }
                .frame(height: 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("확인 필요")
                ForEach(attentionResults) { result in
                    attentionRow(result)
                }
                sectionLabel("통과", top: 12)
                ForEach(passedResults) { result in
                    passedRow(result)
                }
                Text("체크한 항목이 수정 요청 md에 들어가요. 도구 오판은 기본으로 빠져요.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaSecondaryText)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    private func attentionRow(_ result: ScenarioResult) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { appModel.reviewEntry(for: result).include },
                set: { appModel.updateInclude(id: result.id, include: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Button {
                appModel.selectedResultID = result.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.id)
                            .font(.system(size: 12, design: .monospaced))
                        Text(outcomeText(result))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected(result) ? Color.white : outcomeColor(result))
                    }
                    Text("\(title(result)) · \(causeText(result))")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected(result) ? Color.white.opacity(0.88) : Color.qaSecondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected(result) ? Color.white : Color.qaText)
        .background(isSelected(result) ? Color.qaAccent : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func passedRow(_ result: ScenarioResult) -> some View {
        Button {
            appModel.selectedResultID = result.id
        } label: {
            HStack(spacing: 10) {
                Text(result.id)
                    .font(.system(size: 12, design: .monospaced))
                Text(title(result))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected(result) ? Color.white : Color.qaText)
            .background(isSelected(result) ? Color.qaAccent : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("Artemis 호출 \(totals.llmCalls)회")
            Divider().frame(height: 12)
            Text("입력 \(tokens(totals.promptTokens)) · 출력 \(tokens(totals.completionTokens)) 토큰")
            Divider().frame(height: 12)
            Text("판정: Claude Code · \(duration(appModel.judgeDuration))")
            Divider().frame(height: 12)
            Text("메모는 자동 저장돼요")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.qaSecondaryText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.qaBar)
    }

    private var results: [ScenarioResult] {
        appModel.runResults?.scenarios ?? []
    }

    private var attentionResults: [ScenarioResult] {
        results.filter { $0.outcome != .pass }
    }

    private var passedResults: [ScenarioResult] {
        results.filter { $0.outcome == .pass }
    }

    private var selectedResult: ScenarioResult? {
        results.first(where: { $0.id == appModel.selectedResultID }) ?? results.first
    }

    private var totals: ResultViewTotals {
        guard let totals = appModel.runTotals else { return ResultViewTotals() }
        return ResultViewTotals(
            pass: totals.pass,
            fail: totals.fail,
            hold: totals.hold,
            notRun: totals.notRun,
            total: totals.total,
            llmCalls: totals.llmCalls,
            promptTokens: totals.promptTokens,
            completionTokens: totals.completionTokens
        )
    }

    private var tapeCells: [(id: String, calls: Int, state: TapeState)] {
        results.map { result in
            let state: TapeState = switch result.outcome {
            case .pass: .pass
            case .fail: .fail
            case .hold: .hold
            case .notRun, nil: .idle
            }
            return (result.id, appModel.usageCalls(run: runDir, id: result.id), state)
        }
    }

    private func sectionLabel(_ value: String, top: CGFloat = 4) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.qaSecondaryText)
            .padding(.horizontal, 8)
            .padding(.top, top)
            .padding(.bottom, 4)
    }

    private func summaryLabel(_ value: String, color: Color) -> some View {
        Label(value, systemImage: "circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
    }

    private func title(_ result: ScenarioResult) -> String {
        result.title
            ?? appModel.selectedPlan?.scenarios.first(where: { $0.id == result.id })?.title
            ?? "제목 없음"
    }

    private func causeText(_ result: ScenarioResult) -> String {
        appModel.effectiveCause(for: result)?.rawValue ?? result.rawCause ?? "미정"
    }

    private func outcomeText(_ result: ScenarioResult) -> String {
        result.outcome?.rawValue ?? result.rawOutcome ?? "미정"
    }

    private func outcomeColor(_ result: ScenarioResult) -> Color {
        switch result.outcome {
        case .pass: .qaPass
        case .fail: .qaFail
        case .hold: .qaHold
        case .notRun, nil: .qaTertiaryText
        }
    }

    private func isSelected(_ result: ScenarioResult) -> Bool {
        appModel.selectedResultID == result.id
    }

    private func tokens(_ value: Int) -> String {
        guard value >= 1_000_000 else { return value.formatted() }
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "기록 없음" }
        let seconds = Int(value)
        return "\(seconds / 60)분 \(seconds % 60)초"
    }
}

private struct ResultViewTotals {
    var pass = 0
    var fail = 0
    var hold = 0
    var notRun = 0
    var total = 0
    var llmCalls = 0
    var promptTokens = 0
    var completionTokens = 0
}

struct FixRequestView: View {
    @Bindable var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("수정 요청 md")
                        .font(.system(size: 16, weight: .semibold))
                    Text("앱 코드를 고치는 LLM에게 이 파일을 그대로 넘기면 돼요. 계정 값은 들어가지 않아요.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.qaSecondaryText)
                }
                Spacer()
                if copied {
                    Label("복사했어요", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.qaPass)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                includeList
                    .frame(width: 230)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(appModel.fixRequestMarkdown)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("…/runs/…/\(appModel.selectedRun?.lastPathComponent ?? "")/fix-request.md")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.qaSecondaryText)
                Spacer()
                if appModel.selectedProject?.category == .personal {
                    Button("커밋") { Task { await appModel.prepareCommit() } }
                }
                Button("닫기") { dismiss() }
                Button("복사", systemImage: "doc.on.doc") {
                    appModel.copyFixRequest()
                    copied = true
                }
                Button("저장…", systemImage: "square.and.arrow.down") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 900, height: 720)
        .confirmationDialog(
            "이 파일만 커밋하고 push할까요?",
            isPresented: $appModel.isCommitConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("커밋하고 push") { Task { await appModel.commitResults() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(appModel.pendingCommitFiles.joined(separator: "\n"))
        }
    }

    private var includeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("넣을 항목")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            ForEach(attentionResults) { result in
                Toggle(isOn: Binding(
                    get: { appModel.reviewEntry(for: result).include },
                    set: {
                        appModel.updateInclude(id: result.id, include: $0)
                        copied = false
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.id)
                            .font(.system(size: 12, design: .monospaced))
                        Text("\(title(result)) · \(cause(result))")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.qaSecondaryText)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            Spacer()
            Text("결과 화면의 체크와 같은 값이에요.")
                .font(.system(size: 11))
                .foregroundStyle(Color.qaSecondaryText)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.qaSunken.opacity(0.45))
    }

    private var attentionResults: [ScenarioResult] {
        appModel.runResults?.scenarios.filter { $0.outcome != .pass } ?? []
    }

    private func title(_ result: ScenarioResult) -> String {
        result.title
            ?? appModel.selectedPlan?.scenarios.first(where: { $0.id == result.id })?.title
            ?? "제목 없음"
    }

    private func cause(_ result: ScenarioResult) -> String {
        appModel.effectiveCause(for: result)?.rawValue ?? result.rawCause ?? "미정"
    }

    private func save() {
        let panel = NSSavePanel()
        panel.directoryURL = appModel.selectedRun
        panel.nameFieldStringValue = "fix-request.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appModel.exportFixRequest(to: url)
        } catch {
            appModel.notice = AppNotice(title: "저장하지 못했어요", message: error.localizedDescription)
        }
    }
}
