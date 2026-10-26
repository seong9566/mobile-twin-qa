import QATwinCore
import SwiftUI

struct PlanListView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("이번에 돌릴 시나리오")
                            .font(.system(size: 17, weight: .semibold))
                        Text("체크를 끄면 빠져요 · 줄을 끌어 순서를 바꿔요")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.qaSecondaryText)
                        Spacer(minLength: 8)
                        Toggle(isOn: allIncludedBinding) {
                            Text("전체 선택 \(includedCount)/\(appModel.automaticScenarios.count)")
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        .help("자동·반자동 시나리오를 모두 넣거나 모두 뺍니다")
                    }

                    Table(appModel.automaticScenarios, selection: $appModel.selectedScenarioID) {
                        TableColumn("포함") { scenario in
                            Toggle("", isOn: includedBinding(scenario.id))
                                .labelsHidden()
                                .accessibilityLabel("\(scenario.id) 실행에 포함")
                        }
                        .width(42)

                        TableColumn("ID") { scenario in
                            Text(scenario.id)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(appModel.includedScenarioIDs.contains(scenario.id) ? Color.qaText : Color.qaTertiaryText)
                        }
                        .width(70)

                        TableColumn("제목") { scenario in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(scenario.title)
                                    if !SafetyLint.warnings(goal: scenario.goal).isEmpty {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(Color.qaWarn)
                                            .accessibilityLabel("위험 동작 경고")
                                    }
                                }
                                if !scenario.dependsOn.isEmpty {
                                    Text(scenario.dependsOn.joined(separator: ", ") + " 뒤")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.qaTertiaryText)
                                }
                            }
                            .draggable(scenario.id)
                            .dropDestination(for: String.self) { items, _ in
                                guard let source = items.first else { return false }
                                appModel.moveScenario(source, before: scenario.id)
                                return true
                            }
                        }

                        TableColumn("등급") { scenario in
                            Text(gradeLabel(scenario))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(scenario.grade == .B ? Color.qaHold : Color.qaAccentInk)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(
                                    scenario.grade == .B ? Color.qaHoldWeak : Color.qaAccentWeak,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                        .width(120)

                    }

                    if !appModel.manualScenarios.isEmpty || !appModel.manualScenarioText().isEmpty {
                        DisclosureGroup("수동(C) \(appModel.manualScenarioCount)개는 실행하지 않아요 — 목록 보기") {
                            Text(appModel.manualScenarioText())
                                .font(.system(size: 12))
                                .foregroundStyle(Color.qaSecondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(18)
                .frame(minWidth: 440, maxWidth: .infinity)

                if let scenario = appModel.selectedScenario {
                    // 선택이 바뀌면 편집 칸의 초안 상태를 새로 만든다.
                    ScenarioEditor(appModel: appModel, scenario: scenario)
                        .id(scenario.id)
                        .frame(width: 540)
                        .overlay(alignment: .leading) { Divider() }
                } else {
                    ContentUnavailableView("시나리오를 선택해 주세요", systemImage: "checklist")
                        .frame(width: 540)
                        .overlay(alignment: .leading) { Divider() }
                }
            }

            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(includedCount) / \(appModel.automaticScenarios.count)개 실행")
            Divider().frame(height: 12)
            Text("사람 필요 \(appModel.automaticScenarios.count { $0.grade == .B && appModel.includedScenarioIDs.contains($0.id) })")
            Divider().frame(height: 12)
            Text("위험 경고 \(appModel.automaticScenarios.count { !SafetyLint.warnings(goal: $0.goal).isEmpty && appModel.includedScenarioIDs.contains($0.id) })")
            Divider().frame(height: 12)
            Text(appModel.editedScenarioIDs.isEmpty ? "수정 없음" : "저장 안 한 수정 \(appModel.editedScenarioIDs.count)개")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.qaSecondaryText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
    }

    private var includedCount: Int {
        appModel.automaticScenarios.count { appModel.includedScenarioIDs.contains($0.id) }
    }

    private var allIncludedBinding: Binding<Bool> {
        Binding(
            get: { !appModel.automaticScenarios.isEmpty && includedCount == appModel.automaticScenarios.count },
            set: { includeAll in
                let ids = appModel.automaticScenarios.map(\.id)
                if includeAll {
                    appModel.includedScenarioIDs.formUnion(ids)
                } else {
                    appModel.includedScenarioIDs.subtract(ids)
                }
            }
        )
    }

    private func includedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { appModel.includedScenarioIDs.contains(id) },
            set: { included in
                if included {
                    appModel.includedScenarioIDs.insert(id)
                } else {
                    appModel.includedScenarioIDs.remove(id)
                }
            }
        )
    }

    private func gradeLabel(_ scenario: Scenario) -> String {
        if scenario.grade == .B {
            return "B · " + (scenario.gradeNote ?? "반자동")
        }
        return "A · 자동"
    }
}

