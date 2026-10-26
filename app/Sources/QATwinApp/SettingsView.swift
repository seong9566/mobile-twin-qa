import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        Form {
            Section {
                Group {
                    LabeledContent("mobile-twin-qa 루트") {
                        HStack {
                            TextField("폴더를 선택해 주세요", text: binding(\.workspaceRoot))
                            Button("선택…") { chooseWorkspace() }
                        }
                    }
                    LabeledContent("ARTEMIS_HOME") {
                        TextField("~/Desktop/workspace/artemis", text: binding(\.artemisHome))
                    }
                    LabeledContent("ARTEMIS_TRACES_DIR") {
                        TextField("비워 두면 ARTEMIS_HOME/traces", text: binding(\.artemisTracesDir))
                    }
                }
                .disabled(isExecuting)
                LabeledContent("Artemis 주소") {
                    TextField("http://127.0.0.1:8100", text: binding(\.artemisURL))
                }
                LabeledContent("adb 경로") {
                    TextField("비워 두면 기본 설치 경로에서 찾음", text: binding(\.adbPath))
                }
                .disabled(isExecuting)
                LabeledContent("claude 경로") {
                    TextField("~/.local/bin/claude", text: binding(\.claudePath))
                }
            } footer: {
                if isExecuting {
                    Text("실행 중에는 바꿀 수 없어요")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.qaTertiaryText)
                }
            }

            Section("프로젝트 계정 (.env)") {
                if let project = appModel.selectedProject {
                    let keys = appModel.accountEnvKeys(for: project)
                    if keys.isEmpty {
                        Text("이 프로젝트의 계획·project.yaml에 계정 키가 없어요")
                            .foregroundStyle(Color.qaTertiaryText)
                    } else {
                        AccountsSection(
                            keys: keys,
                            envURL: project.dir.appending(path: ".env"),
                            onPresentKeysChange: { _ in }
                        )
                    }
                } else {
                    Text("프로젝트를 먼저 고르세요")
                        .foregroundStyle(Color.qaTertiaryText)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620)
    }

    private var isExecuting: Bool {
        appModel.activeRun != nil || appModel.activeStage != nil
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppModel, String>) -> Binding<String> {
        Binding(
            get: { appModel[keyPath: keyPath] },
            set: { appModel[keyPath: keyPath] = $0 }
        )
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.chooseWorkspaceFolder(url)
    }
}

