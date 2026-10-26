import Foundation

public enum FixRequestRenderer {
    public static func render(
        results: RunResults,
        plan: PlanDocument?,
        review: Review,
        project: String,
        runDirRelative: String
    ) -> String {
        let runName = URL(fileURLWithPath: runDirRelative).lastPathComponent
        var lines = [
            "# \(project) 수정 요청 — \(runName)",
            "",
            "- 소스: \(results.branch ?? "") · \(results.commit ?? "") · 앱 버전 \(results.appVersion ?? "")",
            "- 기기: \(results.device ?? "") · 서버: \(results.server ?? "")",
            "- 실행 기록: `\(runDirRelative)/`",
        ]
        var includesToolMisjudgment = false

        for result in results.scenarios {
            let entry = review.entry(for: result)
            guard entry.include else {
                continue
            }

            let plannedScenario = plan?.scenarios.first(where: { $0.id == result.id })
            let title = plannedScenario?.title ?? result.title ?? ""
            let cause = entry.causeOverride?.rawValue
                ?? result.cause?.rawValue
                ?? nonEmpty(result.rawCause)
                ?? "미정"
            includesToolMisjudgment = includesToolMisjudgment || cause == Cause.toolMisjudgment.rawValue

            lines.append("")
            lines.append("## \(result.id) · \(title)")
            lines.append("")
            lines.append("- 원인 구분: \(cause)")
            if let plannedScenario {
                appendValue(plannedScenario.goal, label: "테스트 순서", to: &lines)
                appendValue(plannedScenario.passCondition, label: "통과 조건", to: &lines)
                appendValue(plannedScenario.evidence, label: "근거 코드", to: &lines)
            }
            appendValue(result.expected, label: "기대", to: &lines)
            appendValue(nonEmpty(result.actual) ?? result.reason, label: "실제", to: &lines)
            let evidencePaths = result.evidence.filter { !$0.isEmpty }
            if !evidencePaths.isEmpty {
                let evidence = evidencePaths.map { "`\(runDirRelative)/\($0)`" }.joined(separator: ", ")
                lines.append("- 녹화·스크린샷: \(evidence)")
            }
            appendValue(entry.memo, label: "수정할 점", to: &lines)
        }

        let accountEnvKeys = plan?.accountEnvKeys.joined(separator: "`, `") ?? ""
        lines.append("")
        lines.append("## 요청")
        lines.append("")
        if accountEnvKeys.isEmpty {
            lines.append("위 항목의 원인을 소스에서 찾아 수정안을 제시해 주세요. 계정·비밀값은 이 문서에 없습니다.")
        } else {
            lines.append("위 항목의 원인을 소스에서 찾아 수정안을 제시해 주세요. 계정·비밀값은 이 문서에 없습니다. 필요하면 환경 변수 이름(`\(accountEnvKeys)`)으로 참조하세요.")
        }
        if includesToolMisjudgment {
            lines.append("원인 구분이 '도구 오판'인 항목은 테스트 도구의 오판일 수 있으니 코드를 고치기 전에 녹화로 먼저 확인해 주세요.")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendValue(_ value: String?, label: String, to lines: inout [String]) {
        guard let value = nonEmpty(value) else {
            return
        }
        lines.append("- \(label): \(value)")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
