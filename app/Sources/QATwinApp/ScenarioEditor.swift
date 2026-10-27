import QATwinCore
import SwiftUI

struct ScenarioEditor: View {
    @Bindable var appModel: AppModel
    let scenario: Scenario

    @State private var draft: Scenario

    init(appModel: AppModel, scenario: Scenario) {
        self.appModel = appModel
        self.scenario = scenario
        _draft = State(initialValue: scenario)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.qaSecondaryText)
                Text(draft.title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    // 사람 개입이 있는 시나리오만 그 동작을 보인다.
                    if !HumanActionChips.actions(for: draft).isEmpty {
                        detail("사람 개입", HumanActionChips.actions(for: draft).joined(separator: " · "))
                    }
                    detail("플랫폼", draft.platform)
                    detail("계정", draft.account.isEmpty ? "로그인 안 함" : draft.account)
                    detail("사전 조건", draft.precondition ?? "없음")
                    detail("근거", (draft.evidence ?? "없음").replacingOccurrences(of: "`", with: ""))
                }
                .font(.system(size: 12))
            }
            .padding(.bottom, 8)

            field("테스트 순서 (goal)", text: Binding(
                get: { draft.goal },
                set: {
                    draft.goal = $0
                    storeDraft()
                }
            ), height: 150)

            ForEach(SafetyLint.warnings(goal: draft.goal), id: \.self) { warning in
                Label(warning + ". 실제 동작이 일어날 수 있어요.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaWarn)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.qaWarnWeak, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaWarnLine))
            }

            field("통과 조건", text: Binding(
                get: { draft.passCondition ?? "" },
                set: {
                    draft.passCondition = $0
                    storeDraft()
                }
            ), height: 80)

            Spacer()
            Text("아직 실행하지 않은 계획이라 이 파일에 저장해요. 실행 기록이 있는 계획을 고치면 새 계획 파일로 저장해요.")
                .font(.system(size: 12))
                .foregroundStyle(Color.qaTertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.qaBar.opacity(0.45))
    }

    private func detail(_ name: String, _ value: String) -> some View {
        // Grid는 값의 이상적인 폭으로 칸을 넓혀 창 밖으로 밀어낸다. 라벨 폭을 고정하고 값은 줄바꿈한다.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .foregroundStyle(Color.qaTertiaryText)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(name == "근거" ? .system(.caption, design: .monospaced) : .system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.qaSecondaryText)
            TextEditor(text: text)
                .font(.system(size: 13))
                .frame(height: height)
                .padding(4)
                .background(Color.qaBackground)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.qaStrongLine))
        }
    }

    private func storeDraft() {
        do {
            try appModel.saveEdits(draft)
        } catch {
            appModel.notice = AppNotice(title: "수정 내용을 반영하지 못했어요", message: error.localizedDescription)
        }
    }
}

