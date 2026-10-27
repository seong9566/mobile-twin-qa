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
            GeometryReader { proxy in
                // 영상은 남는 높이에 맞춰 폰 화면 비율(1080×2400)로 정한다. 창이 낮으면 그만큼 작아진다.
                let videoHeight = max(proxy.size.height - Self.captionHeight, 0)
                let videoWidth = min(videoHeight * Self.phoneAspect, proxy.size.width * 0.45)
                HStack(alignment: .top, spacing: 22) {
                    video(width: videoWidth, height: videoWidth / Self.phoneAspect)
                    // 공간이 넉넉하면 메모 칸이 남는 높이를 채우고, 모자라면 오른쪽 칸만 스크롤한다.
                    ViewThatFits(in: .vertical) {
                        detailColumn(fillsHeight: true)
                        ScrollView {
                            detailColumn(fillsHeight: false)
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

    private func detailColumn(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            expectedActual
            ScrollView {
                checks
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            if result.outcome != .pass {
                memo(fillsHeight: fillsHeight)
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
    }

    private static let phoneAspect: CGFloat = 1080.0 / 2400.0
    /// 영상 아래 경로 캡션: 간격 6 + 11pt 한 줄 ≈ 20, 여유를 둬 26.
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
                causeRow
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
                .lineLimit(1)
                .truncationMode(.middle)
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

    private func memo(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("수정할 점 — md에 그대로 들어가요")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.qaSecondaryText)
                Spacer()
                Toggle("수정 요청 md에 넣기", isOn: includeBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize()
            }
            TextEditor(text: memoBinding)
                .font(.system(size: 13))
                // 이상적 높이를 고정해야 메모가 길어져도 ViewThatFits가 스크롤 쪽으로 바뀌지 않는다.
                .frame(minHeight: 100, idealHeight: 100, maxHeight: fillsHeight ? .infinity : 160)
                .padding(4)
                .scrollContentBackground(.hidden)
                .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.qaStrongLine))
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
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

    /// 실패 원인은 판정 단계에서 Claude가 붙인 분류다. 읽기 전용으로 보여 주고, 사람이 녹화를 보고
    /// 다르다고 판단할 때만 "판정 바로잡기"로 바꾼다. 바꾼 값은 review.json에만 남고 원래 판정은 보존된다.
    private var causeRow: some View {
        // 예전에 원래 판정과 같은 값을 골라 저장된 경우도 "바꾸지 않음"으로 본다.
        let override = appModel.reviewEntry(for: result).causeOverride.flatMap { $0 == result.cause ? nil : $0 }
        let effective = appModel.effectiveCause(for: result)
        let originalLabel = result.cause.map(Self.causeLabel) ?? result.rawCause ?? Self.causeLabel(nil)
        return HStack(spacing: 8) {
            Text("실패 원인")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
                .fixedSize()
            Text(override.map(Self.causeLabel) ?? originalLabel)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
                .help(effective == nil && result.rawCause != nil
                    ? "세 가지 분류에 들지 않는 판정이에요 — 필요하면 바로잡아 주세요"
                    : Self.causeSummary(effective))
            if override != nil {
                Text("내가 바꿈 · 원래 Claude 판정: \(originalLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("되돌리기") { appModel.updateCause(id: result.id, cause: nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .fixedSize()
            } else {
                Text("Claude 판정")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
                    .fixedSize()
            }
            Menu("판정 바로잡기") {
                ForEach(Cause.allCases, id: \.self) { cause in
                    Button(Self.causeLabel(cause)) {
                        appModel.updateCause(id: result.id, cause: cause)
                    }
                    .disabled(cause == effective)
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("녹화를 보고 Claude 판정이 틀렸을 때만 바꿔요")
        }
    }

    /// 화면에 보이는 원인 이름: 분류 · 다음에 할 일
    private static func causeLabel(_ cause: Cause?) -> String {
        switch cause {
        case .appDefect: "앱 결함 · 코드 수정"
        case .toolMisjudgment: "도구 오판 · 수정 불필요"
        case .environment: "환경 · 환경 점검"
        case nil: "미정 · 확인 필요"
        }
    }

    private static func causeSummary(_ cause: Cause?) -> String {
        switch cause {
        case .appDefect: "앱 코드 버그 — 수정 요청 md로 넘길 대상"
        case .toolMisjudgment: "앱은 맞게 동작했고 Artemis가 잘못 판단 — md에서 기본으로 빠져요"
        case .environment: "네트워크·기기·계정처럼 앱 밖의 문제"
        case nil: "원인을 아직 정하지 않았어요"
        }
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
            Text(value).lineSpacing(3).lineLimit(8)
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
