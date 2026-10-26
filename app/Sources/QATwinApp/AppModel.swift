import Foundation
import Observation
import QATwinCore
import SwiftUI

struct Approval {
    var deviceSerial: String
    var server: String
    var scenarioIDs: [String]
    var screenshotApproved: Bool
}

enum AppPhase: Equatable {
    case empty
    case stage(Stage)
    case reviewing
    case running(runDir: URL)
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored @AppStorage("workspaceRoot") var workspaceRoot = ""
    @ObservationIgnored @AppStorage("artemisHome") var artemisHome = "~/Desktop/workspace/artemis"
    @ObservationIgnored @AppStorage("artemisTracesDir") var artemisTracesDir = ""
    @ObservationIgnored @AppStorage("artemisURL") var artemisURL = "http://127.0.0.1:8100"
    @ObservationIgnored @AppStorage("claudePath") var claudePath = ""

    var workspace: Workspace?
    var projects: [ProjectRef] = []
    var selectedProject: ProjectRef?
    var selectedPlan: PlanDocument?
    var selectedRun: URL?
    var phase: AppPhase = .empty
    var orderedScenarios: [Scenario] = []
    var includedScenarioIDs: Set<String> = []
    var selectedScenarioID: String?
    var editedScenarioIDs: Set<String> = []
    var isApprovalPresented = false
    var isCategoryConfirmationPresented = false
    var pendingSourceURL: URL?
    var notice: AppNotice?
    var stageLog = ""
    var stageDecision: String?
    var stageCost: Double?
    var stageStartedAt: Date?
    var stageIsRunning = false
    var rateLimits: ClaudeRateLimits?

    @ObservationIgnored private var claudeRunner: ClaudeRunner?

    init() {
        rateLimits = ClaudeRateLimits.read()
        if !workspaceRoot.isEmpty {
            setWorkspace(from: URL(fileURLWithPath: expandedPath(workspaceRoot)))
        }
    }

    var selectedScenario: Scenario? {
        orderedScenarios.first(where: { $0.id == selectedScenarioID })
    }

    var automaticScenarios: [Scenario] {
        orderedScenarios.filter { $0.grade != .C }
    }

    var manualScenarios: [Scenario] {
        orderedScenarios.filter { $0.grade == .C }
    }

    var manualScenarioCount: Int {
        if !manualScenarios.isEmpty { return manualScenarios.count }
        return manualScenarioText().components(separatedBy: .newlines).count {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
        }
    }

    func chooseWorkspaceFolder(_ url: URL) {
        guard let root = Workspace.locate(from: url) else {
            notice = AppNotice(title: "작업 공간을 찾지 못했어요", message: "mobile-twin-qa 루트 폴더를 선택해 주세요.")
            return
        }
        workspaceRoot = root.path
        setWorkspace(from: root)
    }

    func chooseSourceFolder(_ url: URL) async {
        guard let workspace else {
            notice = AppNotice(title: "작업 공간이 필요해요", message: "먼저 설정에서 mobile-twin-qa 루트를 선택해 주세요.")
            return
        }
        do {
            if let project = try workspace.project(matchingSource: url) {
                selectedProject = project
                try selectNewestPlanIfAvailable(for: project)
                return
            }
            pendingSourceURL = url
            isCategoryConfirmationPresented = true
        } catch {
            show(error)
        }
    }

    func registerPendingSource(as category: ProjectCategory) async {
        guard let source = pendingSourceURL else { return }
        isCategoryConfirmationPresented = false
        pendingSourceURL = nil
        let succeeded = await runStage(.register, prompt: StagePrompt.register(sourcePath: source.path, category: category))
        guard succeeded, let workspace else { return }
        do {
            reloadProjects()
            guard let project = try workspace.project(matchingSource: source) else {
                notice = AppNotice(title: "등록 결과를 찾지 못했어요", message: "프로젝트 등록 결과를 확인해 주세요.")
                return
            }
            selectedProject = project
            await generatePlan()
        } catch {
            show(error)
        }
    }

    func generatePlan() async {
        guard let project = selectedProject else { return }
        let succeeded = await runStage(.plan, prompt: StagePrompt.plan(project: project, scope: nil))
        guard succeeded else { return }
        do {
            guard let planURL = try planURLFromStageOutput(for: project) else {
                notice = AppNotice(title: "계획 파일을 찾지 못했어요", message: "Claude Code 출력과 plans 폴더를 확인해 주세요.")
                return
            }
            try selectPlan(at: planURL)
        } catch {
            show(error)
        }
    }

    func selectProject(_ project: ProjectRef) {
        selectedProject = project
        selectedRun = nil
        do {
            try selectNewestPlanIfAvailable(for: project)
        } catch {
            show(error)
        }
    }

    func selectPlan(at url: URL) throws {
        let plan = try PlanDocument.load(url)
        selectedPlan = plan
        selectedRun = nil
        orderedScenarios = plan.scenarios
        includedScenarioIDs = Set(plan.scenarios.filter { $0.grade != .C }.map(\.id))
        selectedScenarioID = plan.scenarios.first(where: { $0.grade != .C })?.id
        editedScenarioIDs = []
        phase = .reviewing
    }

    func selectRun(_ url: URL) {
        selectedRun = url
    }

    func saveEdits(_ scenario: Scenario) throws {
        guard var plan = selectedPlan else { return }
        plan = try plan.updating(id: scenario.id, goal: scenario.goal, passCondition: scenario.passCondition)
        selectedPlan = plan
        if let index = orderedScenarios.firstIndex(where: { $0.id == scenario.id }) {
            orderedScenarios[index] = scenario
        }
        editedScenarioIDs.insert(scenario.id)
    }

    func savePlan() {
        guard let workspace, let project = selectedProject, let plan = selectedPlan else { return }
        do {
            let hasRuns = try !workspace.runs(of: project, plan: plan.url).isEmpty
            guard let target = PlanSaveTarget.resolve(plan: plan.url, hasRuns: hasRuns, now: .now) else {
                notice = AppNotice(title: "저장할 수 없어요", message: "같은 이름의 계획 파일이 이미 있어요. 잠시 뒤 다시 저장해 주세요.")
                return
            }
            let included = includedScenarioIDs
            let order = orderedScenarios.map(\.id)
            let selection = selectedScenarioID
            try plan.write(to: target)
            let saved = try PlanDocument.load(target)
            selectedPlan = saved
            let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            orderedScenarios = saved.scenarios.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
            includedScenarioIDs = included.intersection(saved.scenarios.map(\.id))
            selectedScenarioID = selection
            editedScenarioIDs = []
            phase = .reviewing
        } catch {
            show(error)
        }
    }

    func moveScenario(_ sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let source = orderedScenarios.firstIndex(where: { $0.id == sourceID }),
              let target = orderedScenarios.firstIndex(where: { $0.id == targetID })
        else { return }
        let scenario = orderedScenarios.remove(at: source)
        let destination = source < target ? target - 1 : target
        orderedScenarios.insert(scenario, at: destination)
    }

    func startRun(_ approval: Approval) async {
        guard let workspace, let project = selectedProject, let plan = selectedPlan else { return }
        isApprovalPresented = false
        do {
            let runDir = try makeRunDirectory(workspace: workspace, project: project, plan: plan.url)
            let prompt = StagePrompt.prepare(
                project: project,
                plan: relativePath(plan.url, from: workspace.root),
                runDir: relativePath(runDir, from: workspace.root),
                deviceSerial: approval.deviceSerial,
                server: approval.server,
                scenarioIDs: approval.scenarioIDs,
                screenshotApproved: approval.screenshotApproved
            )
            let succeeded = await runStage(.prepare, prompt: prompt)
            guard succeeded else { return }
            let output = stageLog
            guard output.contains("준비 완료") else {
                phase = .reviewing
                notice = AppNotice(title: "준비 실패", message: preparationFailure(in: output) ?? "실행 준비 결과를 확인해 주세요.")
                return
            }
            selectedRun = runDir
            phase = .running(runDir: runDir)
        } catch {
            phase = .reviewing
            show(error)
        }
    }

    func cancelStage() {
        claudeRunner?.cancel()
        stageIsRunning = false
    }

    func refreshRateLimits() {
        rateLimits = ClaudeRateLimits.read()
    }

    func plans(for project: ProjectRef) -> [URL] {
        (try? workspace?.plans(of: project)) ?? []
    }

    func runs(for project: ProjectRef, plan: URL) -> [URL] {
        (try? workspace?.runs(of: project, plan: plan)) ?? []
    }

    func tape(for run: URL) -> [(id: String, calls: Int, state: TapeState)] {
        guard let results = try? RunResults.load(runDir: run) else { return [] }
        return results.scenarios.map { result in
            let calls = usageCalls(run: run, id: result.id)
            let state: TapeState = switch result.outcome {
            case .pass: .pass
            case .fail: .fail
            case .hold: .hold
            case .notRun, nil: .idle
            }
            return (result.id, calls, state)
        }
    }

    func environmentNames(for project: ProjectRef) -> [String] {
        let file = project.dir.appending(path: "project.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0 == "environments:" }) else { return [] }
        var names: [String] = []
        for line in lines.dropFirst(start + 1) {
            if !line.isEmpty, line.first?.isWhitespace == false { break }
            let spaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if spaces == 2, trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
                names.append(String(trimmed.dropLast()))
            }
        }
        return names
    }

    func manualScenarioText() -> String {
        guard let plan = selectedPlan,
              let range = plan.text.range(of: #"(?ms)^###?\s+4\.8\s+수동\(C\).*?(?=^##\s|\z)"#, options: .regularExpression)
        else {
            return manualScenarios.map { "\($0.id) · \($0.title)" }.joined(separator: "\n")
        }
        return String(plan.text[range])
            .components(separatedBy: .newlines)
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setWorkspace(from url: URL) {
        guard let root = Workspace.locate(from: url) else { return }
        workspace = Workspace(root: root)
        workspaceRoot = root.path
        reloadProjects()
    }

    private func reloadProjects() {
        do {
            projects = try workspace?.projects() ?? []
        } catch {
            show(error)
        }
    }

    private func selectNewestPlanIfAvailable(for project: ProjectRef) throws {
        guard let workspace, let newest = try workspace.plans(of: project).first else {
            selectedPlan = nil
            orderedScenarios = []
            includedScenarioIDs = []
            phase = .empty
            return
        }
        try selectPlan(at: newest)
    }

    private func runStage(_ stage: Stage, prompt: String) async -> Bool {
        guard let workspace else { return false }
        phase = .stage(stage)
        stageLog = ""
        stageDecision = nil
        stageCost = nil
        stageStartedAt = .now
        stageIsRunning = true
        let runner = ClaudeRunner(executable: resolvedClaudeURL(), workspaceRoot: workspace.root)
        claudeRunner = runner
        do {
            for try await event in runner.run(prompt: prompt) {
                handle(event)
            }
            stageIsRunning = false
            claudeRunner = nil
            return true
        } catch {
            stageIsRunning = false
            claudeRunner = nil
            if !Task.isCancelled {
                notice = AppNotice(title: "Claude Code 실행 실패", message: error.localizedDescription)
            }
            return false
        }
    }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .text(let text):
            appendStageOutput(text)
        case .tool:
            break
        case .result(_, let costUSD, let summary):
            stageCost = costUSD
            appendStageOutput(summary)
        case .rateLimits(let limits):
            rateLimits = limits
        }
    }

    private func appendStageOutput(_ text: String) {
        if !stageLog.isEmpty { stageLog += "\n" }
        stageLog += text
        stageDecision = text.components(separatedBy: .newlines)
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("결정 필요:") })?
            .trimmingCharacters(in: .whitespaces)
    }

    private func planURLFromStageOutput(for project: ProjectRef) throws -> URL? {
        guard let workspace else { return nil }
        for line in stageLog.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("계획:") else { continue }
            let value = String(trimmed.dropFirst("계획:".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " `\t"))
            let url = value.hasPrefix("/")
                ? URL(fileURLWithPath: value)
                : workspace.root.appending(path: value)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return try workspace.plans(of: project).first
    }

    private func makeRunDirectory(workspace: Workspace, project: ProjectRef, plan: URL) throws -> URL {
        let parent = project.dir
            .appending(path: "runs")
            .appending(path: plan.deletingPathExtension().lastPathComponent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        var date = Date.now
        var target = parent.appending(path: formatter.string(from: date))
        while FileManager.default.fileExists(atPath: target.path) {
            date.addTimeInterval(60)
            target = parent.appending(path: formatter.string(from: date))
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private func preparationFailure(in output: String) -> String? {
        output.components(separatedBy: .newlines)
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("준비 실패") })?
            .trimmingCharacters(in: .whitespaces)
    }

    private func resolvedClaudeURL() -> URL {
        let path = claudePath.isEmpty ? "~/.local/bin/claude" : claudePath
        return URL(fileURLWithPath: expandedPath(path))
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func usageCalls(run: URL, id: String) -> Int {
        struct UsageFile: Decodable { let llm_calls: Int }
        let url = run.appending(path: "artifacts/\(id)/usage.json")
        guard let data = try? Data(contentsOf: url),
              let usage = try? JSONDecoder().decode(UsageFile.self, from: data)
        else { return 0 }
        return usage.llm_calls
    }

    private func show(_ error: Error) {
        notice = AppNotice(title: "오류", message: error.localizedDescription)
    }
}
