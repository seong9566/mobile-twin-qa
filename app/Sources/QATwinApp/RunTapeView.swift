import SwiftUI

enum TapeState: Sendable {
    case done
    case running
    case pass
    case fail
    case hold
    case idle

    var color: Color {
        switch self {
        case .done: .qaDone
        case .running: .qaAccent
        case .pass: .qaPass
        case .fail: .qaFail
        case .hold: .qaTapeHold
        case .idle: .qaIdle
        }
    }
}

struct RunTapeView: View {
    let cells: [(id: String, calls: Int, state: TapeState)]
    var mini = false
    var onSelect: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: mini ? 1 : 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Button {
                    onSelect?(cell.id)
                } label: {
                    RoundedRectangle(cornerRadius: mini ? 1 : 2)
                        .fill(cell.state.color)
                        .opacity(cell.state == .running && pulse && !reduceMotion ? 0.45 : 1)
                        .frame(minWidth: mini ? 2 : 6)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(onSelect == nil)
                .frame(maxWidth: CGFloat(max(cell.calls, 1)) * (mini ? 5 : 12))
                .accessibilityLabel("\(cell.id), \(stateLabel(cell.state)), 호출 \(cell.calls)회")
            }
        }
        .frame(height: mini ? 3 : 10)
        .task {
            guard !reduceMotion, cells.contains(where: { $0.state == .running }) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.easeInOut(duration: 0.8)) {
                    pulse.toggle()
                }
            }
        }
    }

    private func stateLabel(_ state: TapeState) -> String {
        switch state {
        case .done: "완료"
        case .running: "진행 중"
        case .pass: "통과"
        case .fail: "실패"
        case .hold: "보류"
        case .idle: "미실행"
        }
    }
}

