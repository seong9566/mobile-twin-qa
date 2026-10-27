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
    let available: Set<PipelineStep>
    /// 이미 끝낸 단계. 지금 보고 있는 화면(current)과 따로 정해서, 앞 단계를 다시 봐도 체크가 사라지지 않는다.
    let completed: Set<PipelineStep>
    let onSelect: (PipelineStep) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(PipelineStep.allCases, id: \.self) { step in
                    // 단계를 누르면 그 단계의 진행 상황·기록 화면으로 간다.
                    Button { onSelect(step) } label: {
                        HStack(spacing: 5) {
                            if completed.contains(step) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.qaPass)
                            }
                            Text(step.rawValue)
                        }
                        .font(.system(size: 12, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(completed.contains(step) || step == current ? Color.qaText : Color.qaSecondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                        .glassEffect(
                            step == current ? .regular.tint(Color.qaAccent.opacity(0.25)) : .identity,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!available.contains(step))
                    .help(available.contains(step) ? "\(step.rawValue) 단계 보기" : "지금 볼 수 있는 \(step.rawValue) 단계가 없어요")

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
}

