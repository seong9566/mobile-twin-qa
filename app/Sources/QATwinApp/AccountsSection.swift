import QATwinCore
import SwiftUI

struct AccountsSection: View {
    let keys: [String]
    let envURL: URL
    let onPresentKeysChange: (Set<String>) -> Void
    var title = "계정"
    /// 키마다 쓰임("로그인"·"빌드"). 비어 있으면 보이지 않는다.
    var usage: [String: String] = [:]
    /// 바뀌면 .env를 다시 읽는다(가져오기 뒤). 입력 중인 값은 그대로 둔다.
    var reloadToken = 0

    @State private var drafts: [String: String] = [:]
    @State private var editing: Set<String> = []
    @State private var presentKeys: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(relativeEnvPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.qaTertiaryText)
            }

            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    accountRow(key)
                    if key != keys.last { Divider() }
                }
            }
            .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaFail)
            }
            Text("값은 이 맥의 .env에만 저장해요. Claude Code·로그·결과 파일에는 키 이름만 들어가요.")
                .font(.system(size: 11))
                .foregroundStyle(Color.qaTertiaryText)
        }
        .onAppear { reload() }
        .onChange(of: envURL) { _, _ in reload() }
        .onChange(of: reloadToken) { _, _ in reload() }
    }

    private func accountRow(_ key: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: presentKeys.contains(key) ? "checkmark" : "exclamationmark.triangle")
                .foregroundStyle(presentKeys.contains(key) ? Color.qaPass : Color.qaWarn)
                .fontWeight(.semibold)
                .accessibilityLabel(presentKeys.contains(key) ? "있음" : "없음")
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 180, alignment: .leading)
            if let use = usage[key] {
                Text(use)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
                    .frame(width: 40, alignment: .leading)
            }

            if presentKeys.contains(key), !editing.contains(key) {
                Text("저장됨")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaTertiaryText)
                Spacer()
                Button("바꾸기") { editing.insert(key) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.qaSecondaryText)
            } else {
                SecureField(presentKeys.contains(key) ? "새 값" : "값을 넣어 주세요", text: draftBinding(key))
                    .textFieldStyle(.roundedBorder)
                if isTooShortToRedact(drafts[key, default: ""]) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.qaWarn)
                        .help("\(SecretRedactor.minimumLength)글자보다 짧은 값은 로그·화면에서 가려지지 않아요")
                        .accessibilityLabel("짧은 값은 가려지지 않음")
                }
                Button("저장") { save(key) }
                    .disabled(drafts[key, default: ""].isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private func isTooShortToRedact(_ value: String) -> Bool {
        !value.isEmpty && value.count < SecretRedactor.minimumLength
    }

    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { drafts[key, default: ""] },
            set: { drafts[key] = $0 }
        )
    }

    private func save(_ key: String) {
        do {
            try EnvFile(url: envURL).upsert(key: key, value: drafts[key, default: ""])
            drafts[key] = nil
            editing.remove(key)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        presentKeys = EnvFile(url: envURL).presentKeys()
        onPresentKeysChange(presentKeys)
    }

    private var relativeEnvPath: String {
        let components = envURL.pathComponents
        return components.suffix(3).joined(separator: "/")
    }
}

