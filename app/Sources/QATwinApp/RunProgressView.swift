import Foundation
import QATwinCore
import SwiftUI

struct RunProgressView: View {
    @Bindable var appModel: AppModel
    let runDir: URL

    @State private var isArtemisLogExpanded = true
    @State private var isPrepareLogExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tapeSection
                    scenarioList
                    // 준비 출력은 이 앱이 지금 돌리는 실행의 것만 있다.
                    if isLive { prepareLog }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Divider()
            statusBar
        }
        .task {
            while !Task.isCancelled {
                appModel.refreshCurrentArtemisLog()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var tapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(progressTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text("칸 폭 = LLM 호출 수")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaSecondaryText)
            }
            RunTapeView(cells: tapeCells)
            HStack(spacing: 16) {
                legend(isLive ? "끝남 · 판정 대기" : "끝남", color: .qaDone)
                legend("진행 중", color: .qaAccent)
                legend("보류", color: .qaTapeHold)
                legend("대기", color: .qaIdle)
            }
        }
    }

    private var scenarioList: some View {
        VStack(spacing: 0) {
            ForEach(Array(scenarios.enumerated()), id: \.element.id) { index, scenario in
                scenarioRow(scenario)
                if index != scenarios.indices.last { Divider() }
            }
        }
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
    }

    @ViewBuilder
    private func scenarioRow(_ scenario: Scenario) -> some View {
        let state = appModel.runStates[scenario.id] ?? .waiting
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(scenario.id)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(isRunning(state) ? .semibold : .regular)
                    .frame(width: 70, alignment: .leading)
                HStack(spacing: 8) {
                    Text(scenario.title)
                    HumanActionChips(scenario: scenario)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stateLabel(state)
                    .frame(width: 150, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(id: scenario.id, at: context.date))
                        .fontWeight(isRunning(state) ? .semibold : .regular)
                }
                .font(.system(size: 12))
                .foregroundStyle(isRunning(state) ? Color.qaText : Color.qaSecondaryText)
                .frame(width: 64, alignment: .leading)
                Text("\(calls(for: scenario.id, state: state))회")
                    .font(.system(size: 12))
                    .fontWeight(isRunning(state) ? .semibold : .regular)
                    .foregroundStyle(isRunning(state) ? Color.qaText : Color.qaSecondaryText)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)

            if isRunning(state) || isSpendLimitState(state) {
                VStack(spacing: 10) {
                    if let signal = appModel.stallSignals[scenario.id] {
                        warning(
                            icon: "clock",
                            text: "멈춤 의심 — \(stallText(signal))",
                            color: .qaFail,
                            background: .qaFailWeak
                        ) {
                            Button("계속 기다리기") {
                                Task { await appModel.keepWaiting(id: scenario.id) }
                            }
                            Button("중지하고 보류") {
                                Task { await appModel.stopCurrentAsHeld() }
                            }
                            .foregroundStyle(Color.qaFail)
                        }
                    }
                    if let reason = appModel.pollFailureReasons[scenario.id] {
                        warning(
                            icon: "exclamationmark.triangle",
                            text: "Artemis 상태를 읽지 못하고 있어요 — \(reason)",
                            color: .qaFail,
                            background: .qaFailWeak
                        ) {
                            Button("중지하고 보류") {
                                Task { await appModel.stopCurrentAsHeld() }
                            }
                            .foregroundStyle(Color.qaFail)
                        }
                    }
                    if appModel.traceLogMissingScenarioIDs.contains(scenario.id) {
                        warning(
                            icon: "doc.badge.ellipsis",
                            text: "Artemis 로그를 찾지 못해 멈춤·지출 한도 감시를 못 하고 있어요 — 설정의 ARTEMIS_HOME·trace 폴더를 확인하세요",
                            color: .qaWarn,
                            background: .qaWarnWeak
                        ) { EmptyView() }
                    }
                    if appModel.adbUnavailableScenarioIDs.contains(scenario.id) {
                        warning(
                            icon: "wifi.exclamationmark",
                            text: "adb를 찾지 못해 Wi-Fi 확인을 못 해요",
                            color: .qaWarn,
                            background: .qaWarnWeak
                        ) { EmptyView() }
                    }
                    if appModel.wifiDownScenarioIDs.contains(scenario.id) {
                        warning(
                            icon: "wifi.slash",
                            text: "Wi-Fi 끊김 — 고친 뒤 끝나면 '다시 돌리기'",
                            color: .qaWarn,
                            background: .qaWarnWeak
                        ) { EmptyView() }
                    }
                    if appModel.spendLimitReached {
                        warning(
                            icon: "exclamationmark.triangle",
                            text: "API 지출 한도에 닿아 멈췄어요 — Console에서 한도를 확인하세요",
                            color: .qaFail,
                            background: .qaFailWeak
                        ) { EmptyView() }
                    }
                    if isRunning(state) {
                        DisclosureGroup(isExpanded: $isArtemisLogExpanded) {
                            ScrollView(.horizontal) {
                                Text(appModel.artemisLog.isEmpty ? "로그를 기다리고 있어요." : appModel.artemisLog)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .background(Color.qaBackground)
                        } label: {
                            Text("Artemis 로그 끝부분")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.qaSecondaryText)
                        }
                        .padding(10)
                        .background(Color.qaSunken, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
                    }
                }
                .padding(.leading, 92)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
        .background(isRunning(state) ? Color.qaAccentWeak.opacity(0.35) : Color.qaBackground)
    }

    private var prepareLog: some View {
        DisclosureGroup(isExpanded: $isPrepareLogExpanded) {
            ScrollView(.horizontal) {
                Text(appModel.stageLog)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.qaBackground)
        } label: {
            Text("준비 단계 Claude Code 출력 — 빌드·설치·로그인 완료")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
        }
        .padding(10)
        .background(Color.qaSunken, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("Artemis 호출 \(appModel.runUsage.llm_calls)회")
            Divider().frame(height: 12)
            Text("입력 \(tokens(appModel.runUsage.prompt_tokens)) · 출력 \(tokens(appModel.runUsage.completion_tokens)) 토큰")
            Divider().frame(height: 12)
            Text(appModel.spendLimitReached
                ? "API 지출 한도: 도달"
                : "API 지출 한도: Console 설정 사용 · 이상 없음")
            Divider().frame(height: 12)
            Text(isLive ? "끝나면 판정을 자동으로 시작해요" : "지난 실행 기록이에요 · 판정은 결과에서 봐요")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.qaSecondaryText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
    }

    private var scenarios: [Scenario] {
        appModel.orderedScenarios.filter { appModel.runStates[$0.id] != nil }
    }

    private var currentIndex: Int? {
        scenarios.firstIndex { scenario in
            guard let state = appModel.runStates[scenario.id] else { return false }
            return isRunning(state)
        }
    }

    /// 지금 이 앱이 돌리는 실행인지. 아니면 run-state.json으로 다시 그린 지난 실행이다.
    private var isLive: Bool {
        appModel.activeRun?.runDir.standardizedFileURL == runDir.standardizedFileURL
    }

    private var progressTitle: String {
        guard isLive else { return "\(scenarios.count)개 실행 기록" }
        guard let currentIndex else { return "\(scenarios.count)개 실행 중" }
        return "\(scenarios.count)개 중 \(currentIndex + 1)번째 진행 중"
    }

    private var tapeCells: [(id: String, calls: Int, state: TapeState)] {
        scenarios.map { scenario in
            let state = appModel.runStates[scenario.id] ?? .waiting
            return (scenario.id, calls(for: scenario.id, state: state), tapeState(state))
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.qaSecondaryText)
    }

    @ViewBuilder
    private func stateLabel(_ state: ScenarioRunState) -> some View {
        switch state {
        case .waiting:
            Label("대기", systemImage: "circle.fill")
                .foregroundStyle(Color.qaTertiaryText)
        case .running:
            HStack(spacing: 6) {
                SwiftUI.ProgressView().controlSize(.small)
                Text("진행 중")
            }
            .foregroundStyle(Color.qaAccentInk)
        case .finished:
            Label(isLive ? "끝남 · 판정 대기" : "끝남", systemImage: "circle.fill")
                .foregroundStyle(Color.qaAccentInk)
        case .held(let reason):
            Label("보류 · \(reason)", systemImage: "circle.fill")
                .foregroundStyle(Color.qaHold)
        case .notRun(let reason):
            Label("미실행 · \(reason)", systemImage: "circle.fill")
                .foregroundStyle(Color.qaTertiaryText)
        }
    }

    private func warning<Actions: View>(
        icon: String,
        text: String,
        color: Color,
        background: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
    }

    private func isRunning(_ state: ScenarioRunState) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func isSpendLimitState(_ state: ScenarioRunState) -> Bool {
        if case .held(let reason) = state { return reason == "API 지출 한도" }
        return false
    }

    private func tapeState(_ state: ScenarioRunState) -> TapeState {
        switch state {
        case .waiting: .idle
        case .running: .running
        case .finished: .done
        case .held: .hold
        case .notRun: .idle
        }
    }

    private func calls(for id: String, state: ScenarioRunState) -> Int {
        if isRunning(state) {
            return appModel.runScenarioCalls[id] ?? 0
        }
        return max(appModel.usageCalls(run: runDir, id: id), appModel.runScenarioCalls[id] ?? 0)
    }

    private func elapsed(id: String, at date: Date) -> String {
        guard let start = appModel.runStartedAt[id] else { return "—" }
        let end = appModel.runFinishedAt[id] ?? date
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func stallText(_ signal: StallSignal) -> String {
        switch signal {
        case .logFrozen(let seconds):
            return "Artemis 로그가 \(seconds / 60)분 \(seconds % 60)초째 그대로예요"
        case .idleLoop(let count):
            return "도구 호출 없이 멈춘 응답이 \(count)회 이어졌어요"
        }
    }

    private func tokens(_ value: Int) -> String {
        guard value >= 1_000_000 else { return value.formatted() }
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }
}
