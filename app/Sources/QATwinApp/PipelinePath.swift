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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PipelineStep.allCases, id: \.self) { step in
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
                .background(step == current ? Color.qaBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: step == current ? .black.opacity(0.12) : .clear, radius: 1, y: 1)

                if step != PipelineStep.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.qaTertiaryText)
                }
            }
        }
        .padding(2)
        .background(Color.qaHover.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("진행 단계")
    }

    private func stepIndex(_ step: PipelineStep?) -> Int {
        guard let step else { return -1 }
        return PipelineStep.allCases.firstIndex(of: step) ?? 0
    }
}

