import Foundation

/// 스킬이 단계마다 출력하는 `진행: <단계> 시작` · `진행: <단계> 끝` 줄로 실제 진행을 읽는다.
public struct StageProgress: Equatable, Sendable {
    /// qa-plan 스킬의 절 순서(범위 확정 → … → 마무리). 스킬의 "앱에서 실행될 때" 절과 이름이 같아야 한다.
    public static let planSteps = ["범위 확정", "소스 맞추기", "지식 정리", "화면 분석", "계획 쓰기", "마무리"]
    static let marker = "진행:"

    /// 끝난 단계.
    public var finished: Set<String> = []
    /// 시작했지만 아직 끝나지 않은 마지막 단계.
    public var current: String?
    /// 진행 줄을 하나라도 봤는지. 없으면 진행 줄을 내지 않는 스킬·단계다.
    public var hasMarkers = false

    public init(log: String) {
        for line in log.components(separatedBy: .newlines) {
            // 모델이 목록 기호·굵게·백틱·마침표를 붙여 써도 읽는다.
            let trimmed = line.trimmingCharacters(in: Self.decoration)
            guard trimmed.hasPrefix(Self.marker) else { continue }
            let body = trimmed.dropFirst(Self.marker.count).trimmingCharacters(in: Self.decoration)
            if body.hasSuffix("끝") {
                guard let step = Self.step(in: String(body.dropLast())) else { continue }
                finished.insert(step)
                if current == step { current = nil }
                hasMarkers = true
            } else if body.hasSuffix("시작") {
                guard let step = Self.step(in: String(body.dropLast(2))) else { continue }
                current = step
                hasMarkers = true
            }
        }
    }

    private static let decoration = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*>`.。"))

    /// "범위 확정(1절)"·"`소스 맞추기`"처럼 꾸민 이름도 planSteps 이름으로 맞춘다. 모르는 이름은 버린다.
    static func step(in raw: String) -> String? {
        let name = raw.trimmingCharacters(in: decoration)
        return planSteps.first { name.hasPrefix($0) } ?? (name.isEmpty ? nil : name)
    }
}

/// 두 글의 줄 단위 차이(빈 줄 제외). 같은 줄이 여러 번 있으면 개수로 비교한다.
public enum LineChanges {
    public static func compare(before: String, after: String) -> (added: [String], removed: [String]) {
        func lines(_ text: String) -> [String] {
            text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var remaining = Dictionary(lines(before).map { ($0, 1) }, uniquingKeysWith: +)
        var added: [String] = []
        for line in lines(after) {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                added.append(line)
            }
        }
        let removed = lines(before).filter { line in
            guard let count = remaining[line], count > 0 else { return false }
            remaining[line] = count - 1
            return true
        }
        return (added, removed)
    }
}

extension PlanDocument {
    /// "## 6. 파일럿" 절에 나온 시나리오 ID. 절이 없으면 제목에 ★파일럿이 붙은 시나리오.
    public var pilotIDs: [String] {
        let ids = Set(scenarios.map(\.id))
        if let range = text.range(of: #"(?ms)^##\s+\d*\.?\s*파일럿.*?(?=^##\s|\z)"#, options: .regularExpression) {
            let section = String(text[range])
            var found: [String] = []
            var searchRange = section.startIndex..<section.endIndex
            while let match = section.range(of: #"[A-Z]{2,5}-\d{2}[a-z]?"#, options: .regularExpression, range: searchRange) {
                let id = String(section[match])
                if ids.contains(id), !found.contains(id) { found.append(id) }
                searchRange = match.upperBound..<section.endIndex
            }
            if !found.isEmpty { return found }
        }
        return scenarios.filter { $0.title.contains("파일럿") }.map(\.id)
    }
}
