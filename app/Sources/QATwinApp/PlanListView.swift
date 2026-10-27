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
                        // 일부만 넣었으면 부분 선택(–)으로 보이고, 누르면 모두 넣는다.
                        Toggle(sources: appModel.automaticScenarios.map { includedBinding($0.id) }, isOn: \.self) {
                            Text("전체 선택 \(includedCount)/\(appModel.automaticScenarios.count)")
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        .help("실행할 시나리오를 모두 넣거나 모두 빼요")
                    }

                    // 끌어 옮기기는 칸이 아니라 행(TableRow)에 둔다. 칸에 두면 첫 클릭을 끌기가 가져가 두 번 눌러야 골라진다.
                    Table(of: Scenario.self, selection: $appModel.selectedScenarioID) {
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
                                Text(scenario.title)
                                if !scenario.dependsOn.isEmpty {
                                    Text(scenario.dependsOn.joined(separator: ", ") + " 뒤")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.qaTertiaryText)
                                }
                            }
                        }

                        TableColumn("사람 개입") { scenario in
                            Text(gradeLabel(scenario))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(scenario.grade == .B ? Color.qaHold : Color.qaAccentInk)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(
                                    scenario.grade == .B ? Color.qaHoldWeak : Color.qaAccentWeak,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                                .help(scenario.grade == .B ? Self.gradeBHelp : Self.gradeAHelp)
                        }
                        .width(120)

                    } rows: {
                        ForEach(appModel.automaticScenarios) { scenario in
                            TableRow(scenario)
                                .draggable(scenario.id)
                                .dropDestination(for: String.self) { items in
                                    guard let source = items.first else { return }
                                    appModel.moveScenario(source, before: scenario.id)
                                }
                        }
                    }

                    Text("사람 개입 — 없음: Artemis가 혼자 끝까지 실행해요 · 적혀 있으면 그 동작을 사람이 해야 해요(시나리오를 시작할 때 알려요) · 처음부터 사람이 해야 하는 시나리오는 실행하지 않고 아래 목록에만 남겨요")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.qaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if !appModel.manualScenarios.isEmpty || !appModel.manualScenarioText().isEmpty {
                        DisclosureGroup("사람이 직접 할 시나리오 \(appModel.manualScenarioCount)개는 실행하지 않아요 — 목록 보기") {
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

    private static let gradeAHelp = "사람 개입 없음: Artemis가 사람 없이 끝까지 실행해요. 판정은 끝난 뒤 Claude가 해요"
    private static let gradeBHelp = "실행 중 사람이 이 동작을 해야 해요. 시나리오를 시작할 때 알림을 보내니 기기 옆에서 지켜봐 주세요"

    private var includedCount: Int {
        appModel.automaticScenarios.count { appModel.includedScenarioIDs.contains($0.id) }
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
            return scenario.gradeNote ?? "있음"
        }
        return "없음"
    }
}

