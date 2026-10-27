import QATwinCore
import SwiftUI

/// 앱이 셸로 실행을 준비하는 화면(목업 4a). Claude Code를 쓰지 않는다.
struct PrepareView: View {
    @Bindable var appModel: AppModel
    @State private var isLogExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title)
                                .font(.system(size: 17, weight: .semibold))
                            Text("앱이 직접 해요 · Claude Code 비용 없음")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.qaSecondaryText)
                        }
                        Text("승인 시트에서 본 점검 항목을 순서대로 해요. 사람이 해야 하는 것만 멈추고 알려요. 끝나면 첫 시나리오부터 Artemis에 보내요.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.qaSecondaryText)
                    }

                    if let failure = appModel.prepareResult.flatMap({ $0.succeeded ? nil : $0.failure }), failure != "사용자 취소" {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("준비가 멈췄어요 — \(failure). 아래 로그 끝부분을 보고 다시 시도하거나 목록으로 돌아가세요. 실행 폴더는 아직 만들지 않았어요.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("다시 시도") { Task { await appModel.retryPrepare() } }
                            Button("목록으로") { Task { await appModel.cancelPrepare() } }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.qaFail)
                        .padding(10)
                        .background(Color.qaFailWeak, in: RoundedRectangle(cornerRadius: 7))
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(PrepareStep.allCases.enumerated()), id: \.element) { index, step in
                            row(step)
                            if index != PrepareStep.allCases.count - 1 { Divider() }
                        }
                    }
                    .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))

                    DisclosureGroup(isExpanded: $isLogExpanded) {
                        ScrollView(.horizontal) {
                            Text(appModel.prepareLogTail.isEmpty ? "로그를 기다리고 있어요." : appModel.prepareLogTail)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .background(Color.qaBackground)
                    } label: {
                        Text("준비 로그 — 명령 출력 끝부분 (계정·키 값은 가려요)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.qaSecondaryText)
                    }
                    .padding(10)
                    .background(Color.qaSunken, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
            }

            Divider()
            HStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("준비 \(elapsed(at: context.date)) 경과")
                }
                Divider().frame(height: 12)
                Text("Claude 비용 $0.00")
                Divider().frame(height: 12)
                Text("준비가 끝나면 시나리오를 자동으로 보내요")
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.qaSecondaryText)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(.bar)
        }
    }

    private var title: String {
        let done = PrepareStep.allCases.count { step in
            switch appModel.prepareItems[step] {
            case .done, .skipped: true
            default: false
            }
        }
        if appModel.prepareResult.map({ !$0.succeeded }) == true { return "실행 준비 멈춤 · \(done) / \(PrepareStep.allCases.count)" }
        if case .waitingForHuman = appModel.prepareItems[.device] {
            return "실행 준비 중 · \(done) / \(PrepareStep.allCases.count) — 기기를 기다려요"
        }
        return "실행 준비 중 · \(done) / \(PrepareStep.allCases.count)"
    }

    private func row(_ step: PrepareStep) -> some View {
        let state = appModel.prepareItems[step] ?? .waiting
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon(state).frame(width: 18)
            Text(name(step))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPending(state) ? Color.qaTertiaryText : Color.qaText)
                .frame(width: 130, alignment: .leading)
            Text(detail(state))
                .font(.system(size: 12))
                .foregroundStyle(color(state))
                .frame(maxWidth: .infinity, alignment: .leading)
            if step == .device, case .waitingForHuman = state {
                Button("다시 확인") { Task { await appModel.recheckPrepareDevice() } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(background(state))
    }

    private func name(_ step: PrepareStep) -> String {
        switch step {
        case .artemis: "Artemis 서버"
        case .server: "테스트 서버"
        case .device: "기기"
        case .build: "빌드"
        case .install: "설치·실행"
        case .login: "로그인"
        case .scenarios: "시나리오"
        }
    }

    private func detail(_ state: PrepareItemState) -> String {
        switch state {
        case .waiting: "대기"
        case .running: "진행 중"
        case .done(let text): text.isEmpty ? "끝났어요" : text
        case .skipped(let text): "건너뜀 · \(text)"
        case .waitingForHuman(let text), .failed(let text): text
        }
    }

    @ViewBuilder
    private func icon(_ state: PrepareItemState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(Color.qaIdle)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Color.qaPass)
        case .skipped: Image(systemName: "minus").foregroundStyle(Color.qaSecondaryText)
        case .waitingForHuman: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.qaWarn)
        case .failed: Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(Color.qaFail)
        }
    }

    private func color(_ state: PrepareItemState) -> Color {
        switch state {
        case .waiting: .qaTertiaryText
        case .running: .qaAccentInk
        case .waitingForHuman: .qaWarn
        case .failed: .qaFail
        default: .qaText
        }
    }

    private func background(_ state: PrepareItemState) -> Color {
        switch state {
        case .running: .qaAccentWeak.opacity(0.35)
        case .waitingForHuman: .qaWarnWeak
        default: .clear
        }
    }

    private func isPending(_ state: PrepareItemState) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(appModel.prepareStartedAt ?? date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
