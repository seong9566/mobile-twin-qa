import AppKit
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
    case results(runDir: URL)
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
    var runEvents: [RunEvent] = []
    var runStates: [String: ScenarioRunState] = [:]
    var runUsage = Usage(llm_calls: 0, prompt_tokens: 0, completion_tokens: 0)
    var runDeviceSerial = ""
    var runServer = ""
    var runScenarioCalls: [String: Int] = [:]
    var runStartedAt: [String: Date] = [:]
    var runFinishedAt: [String: Date] = [:]
    var stallSignals: [String: StallSignal] = [:]
    var wifiDownScenarioIDs: Set<String> = []
    var humanActionNotes: [String: String] = [:]
    var spendLimitReached = false
    var artemisLog = ""
    var runResults: RunResults?
    var runTotals: RunTotals?
    var review = Review()
    var selectedResultID: String?
    var isFixRequestPresented = false
    var judgeDuration: TimeInterval?
    var pendingCommitFiles: [String] = []
    var isCommitConfirmationPresented = false

    @ObservationIgnored private var claudeRunner: ClaudeRunner?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var reviewSaveTask: Task<Void, Never>?
    @ObservationIgnored private var runOrchestrator: RunOrchestrator?

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
        do {
            try loadResults(from: url)
        } catch {
            notice = AppNotice(title: "결과를 열지 못했어요", message: error.localizedDescription)
        }
    }

    func openRun(at url: URL) {
        guard let project = projects.first(where: {
            url.standardizedFileURL.path.hasPrefix($0.dir.standardizedFileURL.path + "/")
        }) else {
            notice = AppNotice(title: "실행을 열지 못했어요", message: "실행 폴더에 해당하는 프로젝트를 찾지 못했어요.")
            return
        }
        selectedProject = project
        let planName = url.deletingLastPathComponent().lastPathComponent + ".md"
        if let planURL = plans(for: project).first(where: { $0.lastPathComponent == planName }) {
            try? selectPlan(at: planURL)
        }
        selectRun(url)
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
        Notifier.requestAuthorization()
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
            runDeviceSerial = approval.deviceSerial
            runServer = approval.server
            let scenarios = orderedScenarios.filter { approval.scenarioIDs.contains($0.id) }
            resetRunState(for: scenarios)
            let orchestrator = makeOrchestrator(
                runDir: runDir,
                plan: plan,
                scenarios: scenarios,
                deviceSerial: approval.deviceSerial,
                server: approval.server
            )
            runOrchestrator = orchestrator
            phase = .running(runDir: runDir)
            await consumeRun(orchestrator, starting: { await orchestrator.start() }, runDir: runDir)
        } catch {
            phase = .reviewing
            show(error)
        }
    }

    func stopCurrentAsHeld() async {
        stallSignals.removeValue(forKey: currentRunningScenarioID ?? "")
        await runOrchestrator?.stopCurrentAsHeld()
    }

    func stopAll() async {
        await runOrchestrator?.stopAll()
        claudeRunner?.cancel()
    }

    func stopAllForTermination() async {
        isTerminating = true
        await stopAll()
        while hasActiveExecution {
            try? await Task.sleep(for: .milliseconds(100))
        }
        claudeRunner?.cancel()
    }

    func keepWaiting(id: String) {
        stallSignals.removeValue(forKey: id)
    }

    func refreshCurrentArtemisLog() {
        guard let sessionID = currentSessionID else {
            artemisLog = ""
            return
        }
        let url = StallDetector.traceLog(
            sessionID: sessionID,
            artemisHome: URL(fileURLWithPath: expandedPath(artemisHome)),
            tracesDir: artemisTracesDir.isEmpty
                ? nil
                : URL(fileURLWithPath: expandedPath(artemisTracesDir))
        )
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            artemisLog = "로그를 기다리고 있어요."
            return
        }
        artemisLog = text.components(separatedBy: .newlines).suffix(200).joined(separator: "\n")
    }

    func updateMemo(id: String, memo: String) {
        guard let result = result(id: id) else { return }
        var entry = review.entry(for: result)
        entry.memo = memo
        review.entries[id] = entry
        scheduleReviewSave()
    }

    func updateCause(id: String, cause: Cause?) {
        guard let result = result(id: id) else { return }
        var entry = review.entry(for: result)
        entry.causeOverride = cause
        if let cause {
            entry.include = cause != .toolMisjudgment
        }
        review.entries[id] = entry
        scheduleReviewSave()
    }

    func updateInclude(id: String, include: Bool) {
        guard let result = result(id: id) else { return }
        var entry = review.entry(for: result)
        entry.include = include
        review.entries[id] = entry
        scheduleReviewSave()
    }

    func reviewEntry(for result: ScenarioResult) -> ReviewEntry {
        review.entry(for: result)
    }

    func effectiveCause(for result: ScenarioResult) -> Cause? {
        review.entry(for: result).causeOverride ?? result.cause
    }

    var includedResultCount: Int {
        guard let runResults else { return 0 }
        return runResults.scenarios.count { review.entry(for: $0).include }
    }

    var fixRequestMarkdown: String {
        guard let runResults, let selectedRun, let selectedProject else { return "" }
        return FixRequestRenderer.render(
            results: runResults,
            plan: selectedPlan,
            review: review,
            project: selectedProject.name,
            runDirRelative: workspace.map { relativePath(selectedRun, from: $0.root) } ?? selectedRun.path
        )
    }

    func exportFixRequest(to url: URL) throws {
        try fixRequestMarkdown.write(to: url, atomically: true, encoding: .utf8)
    }

    func copyFixRequest() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fixRequestMarkdown, forType: .string)
    }

    func prepareCommit() async {
        guard let workspace, let project = selectedProject, project.category == .personal else { return }
        do {
            reviewSaveTask?.cancel()
            if let selectedRun { try review.save(runDir: selectedRun) }
            let projectPath = relativePath(project.dir, from: workspace.root)
            let result = try await ProcessShellRunner().run(
                "/usr/bin/git",
                ["-C", workspace.root.path, "status", "--porcelain=v1", "-z", "--", projectPath]
            )
            guard result.status == 0 else {
                throw shellError(result.out)
            }
            pendingCommitFiles = commitFiles(from: result.out)
            if pendingCommitFiles.isEmpty {
                notice = AppNotice(title: "커밋할 파일이 없어요", message: "프로젝트 폴더에 바뀐 파일이 없어요.")
            } else {
                isCommitConfirmationPresented = true
            }
        } catch {
            show(error)
        }
    }

    func commitResults() async {
        guard let workspace, let project = selectedProject, let selectedRun,
              project.category == .personal, !pendingCommitFiles.isEmpty
        else { return }
        isCommitConfirmationPresented = false
        do {
            let shell = ProcessShellRunner()
            let add = try await shell.run(
                "/usr/bin/git",
                ["-C", workspace.root.path, "add", "--"] + pendingCommitFiles
            )
            guard add.status == 0 else { throw shellError(add.out) }
            let stat = try await shell.run(
                "/usr/bin/git",
                ["-C", workspace.root.path, "diff", "--cached", "--stat", "--"] + pendingCommitFiles
            )
            guard stat.status == 0 else { throw shellError(stat.out) }
            let message = "test(\(project.name)): \(selectedRun.lastPathComponent) 실행 결과"
            let commit = try await shell.run(
                "/usr/bin/git",
                ["-C", workspace.root.path, "commit", "-m", message, "--"] + pendingCommitFiles
            )
            guard commit.status == 0 else { throw shellError(commit.out) }
            let push = try await shell.run("/usr/bin/git", ["-C", workspace.root.path, "push"])
            guard push.status == 0 else { throw shellError(push.out) }
            pendingCommitFiles = []
            notice = AppNotice(title: "커밋했어요", message: message)
        } catch {
            show(error)
        }
    }

    func retryScenario(_ id: String) async {
        guard let orchestrator = runOrchestrator, let runDir = selectedRun else {
            notice = AppNotice(title: "다시 돌릴 수 없어요", message: "이 앱 실행 중에 만든 결과에서만 다시 돌릴 수 있어요.")
            return
        }
        phase = .running(runDir: runDir)
        await consumeRun(orchestrator, starting: { await orchestrator.retry(id: id) }, runDir: runDir)
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

    private var currentRunningScenarioID: String? {
        runStates.first { _, state in
            if case .running = state { return true }
            return false
        }?.key
    }

    private var hasActiveExecution: Bool {
        if case .running = phase { return true }
        return stageIsRunning
    }

    private var currentSessionID: String? {
        guard let id = currentRunningScenarioID,
              case .running(let sessionID) = runStates[id]
        else { return nil }
        return sessionID
    }

    private func resetRunState(for scenarios: [Scenario]) {
        runEvents = []
        runStates = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, .waiting) })
        runUsage = Usage(llm_calls: 0, prompt_tokens: 0, completion_tokens: 0)
        runStartedAt = [:]
        runFinishedAt = [:]
        runScenarioCalls = [:]
        stallSignals = [:]
        wifiDownScenarioIDs = []
        humanActionNotes = [:]
        spendLimitReached = false
        artemisLog = ""
    }

    private func makeOrchestrator(
        runDir: URL,
        plan: PlanDocument,
        scenarios: [Scenario],
        deviceSerial: String,
        server: String
    ) -> RunOrchestrator {
        RunOrchestrator(
            api: ArtemisClient(base: URL(string: artemisURL) ?? URL(string: "http://127.0.0.1:8100")!),
            shell: ProcessShellRunner(),
            runDir: runDir,
            plan: plan,
            scenarios: scenarios,
            deviceSerial: deviceSerial,
            server: server,
            artemisHome: URL(fileURLWithPath: expandedPath(artemisHome)),
            tracesDir: artemisTracesDir.isEmpty
                ? nil
                : URL(fileURLWithPath: expandedPath(artemisTracesDir))
        )
    }

    private func consumeRun(
        _ orchestrator: RunOrchestrator,
        starting operation: @escaping @Sendable () async -> Void,
        runDir: URL
    ) async {
        let operationTask = Task { await operation() }
        for await event in orchestrator.events {
            handle(event)
            if case .finished = event { break }
        }
        await operationTask.value
        guard !isTerminating else {
            phase = .empty
            return
        }
        guard let project = selectedProject, let plan = selectedPlan else { return }
        let started = Date.now
        _ = await runStage(
            .judge,
            prompt: StagePrompt.judge(
                project: project,
                plan: workspace.map { relativePath(plan.url, from: $0.root) } ?? plan.url.path,
                runDir: workspace.map { relativePath(runDir, from: $0.root) } ?? runDir.path
            )
        )
        judgeDuration = Date.now.timeIntervalSince(started)
        do {
            try loadResults(from: runDir)
        } catch {
            phase = .results(runDir: runDir)
            show(error)
        }
    }

    private func handle(_ event: RunEvent) {
        runEvents.append(event)
        switch event {
        case .state(let id, let state):
            runStates[id] = state
            switch state {
            case .running:
                runStartedAt[id] = runStartedAt[id] ?? .now
            case .finished, .held, .notRun:
                runFinishedAt[id] = .now
            case .waiting:
                break
            }
        case .usage(let usage):
            runUsage = usage
            if let id = currentRunningScenarioID {
                let completed = runStates.reduce(into: 0) { total, pair in
                    guard pair.key != id, case .finished = pair.value, let selectedRun else { return }
                    total += usageCalls(run: selectedRun, id: pair.key)
                }
                runScenarioCalls[id] = max(0, usage.llm_calls - completed)
            }
        case .stall(let id, let signal):
            stallSignals[id] = signal
            Notifier.send(title: "\(id): 멈춤 의심", body: stallDescription(signal))
        case .wifiDown(let id):
            wifiDownScenarioIDs.insert(id)
            Notifier.send(title: "\(id): Wi-Fi 끊김", body: "고친 뒤 끝나면 다시 돌릴 수 있어요.")
        case .humanAction(let id, let note):
            humanActionNotes[id] = note
            Notifier.send(title: "\(id): \(note)", body: "사람이 할 동작을 진행해 주세요.")
        case .spendLimitReached:
            spendLimitReached = true
            Notifier.send(
                title: "API 지출 한도",
                body: "Console에서 한도를 확인해 주세요."
            )
        case .finished:
            break
        }
    }

    private func loadResults(from runDir: URL) throws {
        let loaded = try RunResults.load(runDir: runDir)
        selectedRun = runDir
        runResults = loaded
        runTotals = RunTotals.compute(loaded, runDir: runDir)
        review = Review.load(runDir: runDir)
        selectedResultID = loaded.scenarios.first(where: { $0.outcome != .pass })?.id
            ?? loaded.scenarios.first?.id
        phase = .results(runDir: runDir)
    }

    private func result(id: String) -> ScenarioResult? {
        runResults?.scenarios.first(where: { $0.id == id })
    }

    private func scheduleReviewSave() {
        guard let selectedRun else { return }
        reviewSaveTask?.cancel()
        let value = review
        reviewSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? value.save(runDir: selectedRun)
        }
    }

    private func stallDescription(_ signal: StallSignal) -> String {
        switch signal {
        case .logFrozen(let seconds):
            return "Artemis 로그가 \(seconds / 60)분째 그대로예요."
        case .idleLoop(let count):
            return "도구 호출 없이 멈춘 응답이 \(count)회 이어졌어요."
        }
    }

    private func shellError(_ output: String) -> NSError {
        NSError(
            domain: "QATwinApp.Shell",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "명령 실행에 실패했어요." : output]
        )
    }

    private func commitFiles(from output: String) -> [String] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }
            let status = String(record.prefix(2))
            files.append(String(record.dropFirst(3)))
            if status.contains("R") || status.contains("C") {
                index += 1
                if index < records.count { files.append(records[index]) }
            }
            index += 1
        }
        return Array(Set(files)).sorted()
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

    func usageCalls(run: URL, id: String) -> Int {
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
