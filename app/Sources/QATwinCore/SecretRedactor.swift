import Foundation

/// Claude Code 출력을 화면에 보이기 전에 .env 값을 가린다.
public enum SecretRedactor {
    public static let mask = "****"

    /// 긴 값부터 바꿔서 다른 값을 품은 값도 통째로 가린다.
    public static func redact(_ text: String, values: [String]) -> String {
        Set(values.filter { !$0.isEmpty })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
    }
}
