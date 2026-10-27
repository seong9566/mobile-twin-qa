import Foundation

/// Claude Code 출력을 화면에 보이기 전에 .env 값을 가린다.
public enum SecretRedactor {
    public static let mask = "****"
    /// 이보다 짧은 값은 가리지 않는다. 화면에서 값을 받을 때 경고하는 기준이기도 하다.
    public static let minimumLength = 3

    /// 긴 값부터 바꿔서 다른 값을 품은 값도 통째로 가린다.
    /// 로그·스트림 JSON 안에 이스케이프되어 들어간 값(`\"`, `\\`, `\/`, `\uXXXX`)도 함께 가린다.
    /// truncationMarker를 주면 계속 늘어나는 로그의 끝부분으로 보고 값 조각도 가린다:
    /// 그 표식으로 시작하는 줄(앞을 잘라 낸 줄)의 맨 앞 조각과, 아직 쓰는 중일 수 있는 마지막 줄의 맨 끝 조각.
    public static func redact(_ text: String, values: [String], truncationMarker: String? = nil) -> String {
        // 아주 짧은 값은 보통 글자까지 가리고 비밀값으로서 의미도 없으므로 건너뛴다.
        let secrets = Set(values.filter { $0.count >= minimumLength }.flatMap(forms))
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let redacted = secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
        guard let truncationMarker else { return redacted }
        var lines = redacted.components(separatedBy: "\n")
        for index in lines.indices where lines[index].hasPrefix(truncationMarker) {
            let rest = lines[index].dropFirst(truncationMarker.count)
            if let fragment = edgeFragment(of: secrets, where: { rest.hasPrefix($0) }, cut: { $0.suffix($1) }) {
                lines[index] = truncationMarker + mask + rest.dropFirst(fragment.count)
            }
        }
        if let last = lines.indices.last,
           let fragment = edgeFragment(of: secrets, where: { lines[last].hasSuffix($0) }, cut: { $0.prefix($1) }) {
            lines[last] = lines[last].dropLast(fragment.count) + mask
        }
        return lines.joined(separator: "\n")
    }

    /// 값의 앞(prefix)이나 뒤(suffix) 조각 가운데 matches를 만족하는 가장 긴 것. 값 전체는 이미 가렸다.
    private static func edgeFragment(
        of secrets: [String],
        where matches: (String) -> Bool,
        cut: (String, Int) -> Substring
    ) -> String? {
        for value in secrets {
            for length in stride(from: value.count - 1, through: minimumLength, by: -1) {
                let fragment = String(cut(value, length))
                if matches(fragment) { return fragment }
            }
        }
        return nil
    }

    /// 값 그대로와 JSON 문자열 안에 들어갔을 때의 모양(한 번·두 번 이스케이프).
    static func forms(_ value: String) -> [String] {
        var result: Set<String> = [value]
        for once in jsonEscapes(value) {
            result.insert(once)
            result.formUnion(jsonEscapes(once))
        }
        return Array(result)
    }

    /// Swift JSONEncoder(`/`를 `\/`로)와 Python json.dumps(비ASCII를 `\uXXXX`로)가 만드는 모양.
    static func jsonEscapes(_ value: String) -> Set<String> {
        let plain = escape(value, slash: false, ascii: false)
        return [
            plain,
            escape(value, slash: true, ascii: false),
            escape(value, slash: false, ascii: true),
            escape(value, slash: false, ascii: true, uppercaseHex: true),
        ]
    }

    private static func escape(_ value: String, slash: Bool, ascii: Bool, uppercaseHex: Bool = false) -> String {
        func hex(_ unit: UInt16) -> String {
            let digits = String(unit, radix: 16, uppercase: uppercaseHex)
            return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
        }
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/" where slash: out += "\\/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += hex(UInt16(scalar.value))
            case _ where ascii && scalar.value > 0x7E:
                out += String(scalar).utf16.map(hex).joined()
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
