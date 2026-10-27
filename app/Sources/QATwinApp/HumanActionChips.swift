import QATwinCore
import SwiftUI

/// 사람이 해야 하는 동작을 칩으로 나열한다. 사람 개입이 없는 시나리오는 아무것도 그리지 않는다.
struct HumanActionChips: View {
    let scenario: Scenario

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.actions(for: scenario), id: \.self) { action in
                Text(action)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.qaHold)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.qaHoldWeak, in: Capsule())
            }
        }
    }

    /// 계획의 등급 메모(예: "사람이 로그인", "태그 · 두 번째 기기")를 동작 하나씩 나눈다.
    static func actions(for scenario: Scenario) -> [String] {
        guard scenario.grade == .B else { return [] }
        let parts = (scenario.gradeNote ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "·,/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["사람 확인"] : parts
    }
}
