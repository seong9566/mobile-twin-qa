import Foundation

/// Claude Code 출력을 화면에 보이기 전에 .env 값을 가린다.
public enum SecretRedactor {
    public static let mask = "****"
    /// 이보다 짧은 값은 가리지 않는다. 화면에서 값을 받을 때 경고하는 기준이기도 하다.
    public static let minimumLength = 3

    /// 긴 값부터 바꿔서 다른 값을 품은 값도 통째로 가린다.
    /// 로그·스트림 JSON 안에 이스케이프되어 들어간 값(`\"`, `\\`, `\/`, `\uXXXX`)도 함께 가린다.
    /// maskingEdgeFragments가 true면 마지막 줄의 앞뒤에 걸친 값 조각도 가린다
    /// (앞부분을 잘라 낸 줄, 아직 쓰는 중인 줄).
    public static func redact(_ text: String, values: [String], maskingEdgeFragments: Bool = false) -> String {
        // 아주 짧은 값은 보통 글자까지 가리고 비밀값으로서 의미도 없으므로 건너뛴다.
        let secrets = values.filter { $0.count >= minimumLength }
        let redacted = Set(secrets.flatMap(forms))
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
        guard maskingEdgeFragments else { return redacted }
        return maskLastLineEdges(redacted, values: secrets)
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

    /// 마지막 줄이 값의 뒷부분으로 시작하거나 값의 앞부분으로 끝나면 그 조각을 가린다.
    private static func maskLastLineEdges(_ text: String, values: [String]) -> String {
        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        var line = String(text[lineStart...])
        guard !line.isEmpty else { return text }
        let longestFirst = values.sorted { $0.count > $1.count }
        if let fragment = longestFirst.lazy.compactMap({ value in
            fragments(of: value).first { line.hasPrefix(String(value.suffix($0))) }.map { String(value.suffix($0)) }
        }).first {
            line = mask + line.dropFirst(fragment.count)
        }
        if let fragment = longestFirst.lazy.compactMap({ value in
            fragments(of: value).first { line.hasSuffix(String(value.prefix($0))) }.map { String(value.prefix($0)) }
        }).first, line != mask {
            line = line.dropLast(fragment.count) + mask
        }
        return text[..<lineStart] + line
    }

    /// 값보다 짧은 조각 길이, 긴 것부터. 값 전체는 앞에서 이미 가렸다.
    private static func fragments(of value: String) -> StrideThrough<Int> {
        stride(from: value.count - 1, through: minimumLength, by: -1)
    }
}
