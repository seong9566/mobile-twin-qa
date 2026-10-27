import QATwinCore
import SwiftUI

/// 원본 repo의 `.env`에서 고른 키만 프로젝트 `.env`로 가져온다(스펙 5.2). 값은 보이지 않는다.
struct EnvImportSheet: View {
    let sourceDir: URL
    let envSource: String
    let projectEnv: URL
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [EnvImport.Candidate] = []
    @State private var checked: Set<String> = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("원본 .env에서 가져오기")
                .font(.system(size: 16, weight: .semibold))
            Text(sourceDir.appending(path: envSource).path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.qaTertiaryText)
                .textSelection(.enabled)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaWarn)
            } else {
                Text("가져올 키를 고르세요. .env.example에 있는 키가 기본으로 골라져 있어요.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaSecondaryText)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates, id: \.key) { candidate in
                            Toggle(isOn: Binding(
                                get: { checked.contains(candidate.key) },
                                set: { if $0 { checked.insert(candidate.key) } else { checked.remove(candidate.key) } }
                            )) {
                                Text(candidate.key).font(.system(.caption, design: .monospaced))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("가져오기") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty || errorMessage != nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .task {
            do {
                candidates = try await EnvImport.candidates(sourceDir: sourceDir, envSource: envSource, shell: ProcessShellRunner())
                checked = Set(candidates.filter(\.defaultChecked).map(\.key))
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func apply() {
        do {
            try EnvImport.apply(keys: candidates.map(\.key).filter(checked.contains), from: sourceDir.appending(path: envSource), to: projectEnv)
            onDone()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
