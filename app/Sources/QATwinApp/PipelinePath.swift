import SwiftUI

enum PipelineStep: String, CaseIterable {
    case register = "등록"
    case plan = "계획"
    case review = "목록 확인"
    case run = "실행"
    case results = "결과"
}

struct PipelinePath: View {
    let current: PipelineStep?
    let isAvailable: (PipelineStep) -> Bool
    let onSelect: (PipelineStep) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(PipelineStep.allCases, id: \.self) { step in
                    // 단계를 누르면 그 단계의 진행 상황·기록 화면으로 간다.
                    Button { onSelect(step) } label: {
                        HStack(spacing: 5) {
                            if stepIndex(step) < stepIndex(current) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.qaPass)
                            }
                            Text(step.rawValue)
                        }
                        .font(.system(size: 12, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(stepIndex(step) <= stepIndex(current) ? Color.qaText : Color.qaSecondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                        .glassEffect(
                            step == current ? .regular.tint(Color.qaAccent.opacity(0.25)) : .identity,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable(step))
                    .help(isAvailable(step) ? "\(step.rawValue) 단계 보기" : "아직 볼 \(step.rawValue) 단계가 없어요")

                    if step != PipelineStep.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.qaTertiaryText)
                    }
                }
            }
            .padding(2)
            .glassEffect(.regular, in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("진행 단계")
    }

    private func stepIndex(_ step: PipelineStep?) -> Int {
        guard let step else { return -1 }
        return PipelineStep.allCases.firstIndex(of: step) ?? 0
    }
}

