import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        Form {
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
            LabeledContent("Artemis 주소") {
                TextField("http://127.0.0.1:8100", text: binding(\.artemisURL))
            }
            LabeledContent("claude 경로") {
                TextField("~/.local/bin/claude", text: binding(\.claudePath))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620)
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

