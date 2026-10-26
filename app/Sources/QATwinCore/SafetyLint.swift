public enum SafetyLint {
    public static func warnings(goal: String) -> [String] {
        if goal.contains("누르지 마") || goal.contains("하지 마") {
            return []
        }

        return ["전화", "발신", "삭제", "결제", "송금", "구매", "탈퇴"].compactMap { word in
            goal.contains(word) ? "'\(word)' 동작이 있는데 \"누르지 마\"가 없어요" : nil
        }
    }
}
