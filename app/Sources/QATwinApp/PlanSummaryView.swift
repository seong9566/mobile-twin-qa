import QATwinCore
import SwiftUI

/// 계획을 다 쓴 뒤 목록 확인으로 넘어가기 전 요약.
struct PlanSummaryView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        ScrollView {
            if let summary = appModel.planSummary {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.qaPass)
                            Text("계획을 다 썼어요")
                        }
                        .font(.system(size: 22, weight: .semibold))
                        Text(summary.planURL.lastPathComponent)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.qaSecondaryText)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        count("Artemis 혼자", summary.automatic)
                        count("사람 개입", summary.human)
                        count("사람이 직접", summary.manual)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        label("파일럿 — 먼저 돌려 보기 좋은 시나리오")
                        if summary.pilots.isEmpty {
                            Text("계획에 파일럿이 없어요").foregroundStyle(Color.qaTertiaryText)
                        } else {
                            ForEach(summary.pilots, id: \.self) { pilot in
                                Label(pilot, systemImage: "star")
                            }
                        }
                    }
                    .font(.system(size: 13))

                    VStack(alignment: .leading, spacing: 8) {
                        label("함께 바뀐 파일")
                        if summary.changes.isEmpty {
                            Text("knowledge.md · project.yaml 변경 없음")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.qaTertiaryText)
                        }
                        ForEach(summary.changes) { change in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(change.removed.enumerated()), id: \.offset) { _, line in
                                        diffLine("−", line, color: .qaFail)
                                    }
                                    ForEach(Array(change.added.enumerated()), id: \.offset) { _, line in
                                        diffLine("+", line, color: .qaPass)
                                    }
                                }
                                .padding(.top, 6)
                            } label: {
                                Text("\(change.name)  +\(change.added.count) · −\(change.removed.count)")
                                    .font(.system(size: 13, design: .monospaced))
                            }
                            .padding(12)
                            .background(Color.qaSunken, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
                        }
                    }

                    HStack {
                        Spacer()
                        Button("목록 확인으로", systemImage: "list.bullet") { appModel.openSummarizedPlan() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.qaButtonTint)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.qaSecondaryText)
    }

    private func count(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.qaSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.qaLine))
    }

    private func diffLine(_ sign: String, _ line: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign).foregroundStyle(color)
            Text(line).textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
