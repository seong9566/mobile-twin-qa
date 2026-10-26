public enum SafetyLint {
    private static let dangerWords = ["전화", "발신", "삭제", "결제", "송금", "구매", "탈퇴"]
    private static let negations = ["누르지 마", "하지 마", "누르지 말", "하지 말"]

    /// 위험한 낱말이 있는 문장에 그 문장 안의 금지 표현이 없으면 경고한다.
    public static func warnings(goal: String) -> [String] {
        let sentences = goal.split(whereSeparator: { ".!?;\n".contains($0) })
        let unguarded = sentences.filter { sentence in
            !negations.contains { sentence.contains($0) }
        }

        return dangerWords.compactMap { word in
            unguarded.contains { $0.contains(word) } ? "'\(word)' 동작이 있는데 \"누르지 마\"가 없어요" : nil
        }
    }
}
