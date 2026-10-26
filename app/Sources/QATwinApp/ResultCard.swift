import AVKit
import Foundation
import QATwinCore
import SwiftUI

struct ResultCard: View {
    @Bindable var appModel: AppModel
    let result: ScenarioResult
    let runDir: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            rawValues
            // 영상이 남는 높이를 다 쓰도록 폰 화면 비율(1080×2400)로 폭을 정한다.
            GeometryReader { proxy in
                let videoHeight = max(proxy.size.height - Self.captionHeight, 320)
                let videoWidth = min(max(videoHeight * Self.phoneAspect, 240), proxy.size.width * 0.45)
                HStack(alignment: .top, spacing: 22) {
                    video(width: videoWidth, height: videoWidth / Self.phoneAspect)
                    VStack(alignment: .leading, spacing: 16) {
                        expectedActual
                        ScrollView {
                            checks
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: result.outcome == .pass ? .infinity : 260)
                        .fixedSize(horizontal: false, vertical: result.outcome != .pass)
                        if result.outcome != .pass {
                            memo
                            actions
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.qaBackground)
    }

    private static let phoneAspect: CGFloat = 1080.0 / 2400.0
    private static let captionHeight: CGFloat = 26

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(result.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.qaSecondaryText)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                outcomeLabel
                    .fixedSize()
                Spacer(minLength: 0)
            }
            if result.outcome != .pass {
                HStack(spacing: 8) {
                    Text("원인")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.qaSecondaryText)
                    Picker("원인", selection: causeBinding) {
                        Text("앱 결함").tag(Optional(Cause.appDefect))
                        Text("도구 오판").tag(Optional(Cause.toolMisjudgment))
                        Text("환경").tag(Optional(Cause.environment))
                        Text("미정").tag(Optional<Cause>.none)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var rawValues: some View {
        if result.rawOutcome != nil || result.rawCause != nil {
            HStack(spacing: 12) {
                if let rawOutcome = result.rawOutcome {
                    Text("원래 결과: \(rawOutcome)")
                }
                if let rawCause = result.rawCause {
                    Text("원래 판정: \(rawCause)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.qaTertiaryText)
        }
    }

    private func video(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = Artifacts.video(runDir: runDir, id: result.id) {
                    ResultVideo(url: url)
                        .id(url)
                } else {
                    ZStack {
                        Color(red: 0.086, green: 0.094, blue: 0.11)
                        VStack(spacing: 10) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 38, weight: .light))
                            Text("녹화 없음")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color.qaVideoText.opacity(0.9))
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("artifacts/\(result.id)/video.mp4")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.qaTertiaryText)
        }
        .frame(width: width)
    }

    private var expectedActual: some View {
        HStack(alignment: .top, spacing: 10) {
            valueBox(label: "기대", value: result.expected ?? plannedScenario?.passCondition ?? "—", color: .qaBackground)
            valueBox(label: "실제", value: result.actual ?? result.reason ?? "—", color: actualBackground)
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artemis 확인 항목")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
            if let summary = Artifacts.checksSummary(runDir: runDir, id: result.id) {
                Text("통과 \(summary.passed) · 실패 \(summary.failed)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
            }
            let values = ArtemisCheck.load(runDir: runDir, id: result.id)
            if values.isEmpty {
                Text("확인 항목 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaTertiaryText)
            } else {
                ForEach(values) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.passed ? "checkmark" : "xmark")
                            .fontWeight(.bold)
                            .foregroundStyle(check.passed ? Color.qaPass : Color.qaFail)
                        Text(check.text)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var memo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("수정할 점 — md에 그대로 들어가요")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
            TextEditor(text: memoBinding)
                .font(.system(size: 13))
                .frame(minHeight: 120, maxHeight: .infinity)
                .padding(4)
                .scrollContentBackground(.hidden)
                .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.qaStrongLine))
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Toggle("수정 요청 md에 넣기", isOn: includeBinding)
                .toggleStyle(.checkbox)
            Spacer()
            if canRetry {
                Button("이 시나리오만 다시 돌리기", systemImage: "arrow.counterclockwise") {
                    Task { await appModel.retryScenario(result.id) }
                }
            }
        }
    }

    private var outcomeLabel: some View {
        Label(outcomeText, systemImage: "circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(outcomeColor)
    }

    private var title: String {
        result.title ?? plannedScenario?.title ?? "제목 없음"
    }

    private var plannedScenario: Scenario? {
        appModel.selectedPlan?.scenarios.first(where: { $0.id == result.id })
    }

    private var outcomeText: String {
        result.outcome?.rawValue ?? result.rawOutcome ?? "미정"
    }

    private var outcomeColor: Color {
        switch result.outcome {
        case .pass: .qaPass
        case .fail: .qaFail
        case .hold: .qaHold
        case .notRun, nil: .qaTertiaryText
        }
    }

    private var actualBackground: Color {
        switch result.outcome {
        case .pass: .qaPassWeak
        case .fail: .qaFailWeak
        case .hold: .qaHoldWeak
        case .notRun, nil: .qaSunken
        }
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { appModel.reviewEntry(for: result).memo },
            set: { appModel.updateMemo(id: result.id, memo: $0) }
        )
    }

    private var includeBinding: Binding<Bool> {
        Binding(
            get: { appModel.reviewEntry(for: result).include },
            set: { appModel.updateInclude(id: result.id, include: $0) }
        )
    }

    private var causeBinding: Binding<Cause?> {
        Binding(
            get: { appModel.effectiveCause(for: result) },
            set: { appModel.updateCause(id: result.id, cause: $0) }
        )
    }

    private var canRetry: Bool {
        guard result.outcome == .hold,
              appModel.effectiveCause(for: result) == .environment,
              appModel.canRetry(in: runDir)
        else { return false }
        return !FileManager.default.fileExists(
            atPath: runDir.appending(path: "artifacts/\(result.id)/try1").path
        )
    }

    private func valueBox(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.qaTertiaryText)
            Text(value).lineSpacing(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(color, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
    }
}

private struct ResultVideo: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
    }
}

private struct ArtemisCheck: Identifiable {
    let id: Int
    let passed: Bool
    let text: String

    static func load(runDir: URL, id: String) -> [ArtemisCheck] {
        let url = runDir.appending(path: "artifacts/\(id)/checks.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        let values = records.enumerated().reversed().compactMap { index, record -> ArtemisCheck? in
            let checkpointID = record["checkpoint_id"] as? String
            let text = record["item_text"] as? String ?? record["subgoal_text"] as? String
            let key: String? = if let checkpointID, !checkpointID.isEmpty {
                "checkpoint:\(checkpointID)"
            } else if let text {
                "text:\(text)"
            } else {
                nil
            }
            if let key, !seen.insert(key).inserted { return nil }
            guard let text else { return nil }
            return ArtemisCheck(id: index, passed: record["status"] as? String == "passed", text: text)
        }
        return Array(values.reversed())
    }
}
