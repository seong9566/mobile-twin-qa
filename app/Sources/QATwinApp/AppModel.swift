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
    /// 승인 시트에서 고른 로그인 역할(project.yaml `accounts`의 키). 계정이 없으면 nil.
    var loginRole: String?
    var forceRebuild: Bool
}

struct ActiveRun {
    let runDir: URL
    let project: ProjectRef
    let plan: PlanDocument
    let scenarioIDs: [String]
}

enum AppPhase: Equatable {
    case empty
    case stage(Stage)
    /// 지금 돌지 않는 등록·계획 단계의 마지막 기록.
    case stageRecord(Stage)
    /// 새 계획을 쓰기 전 범위·기준 소스를 확인하는 화면.
    case planSetup
    /// 계획을 다 쓴 뒤 목록 확인으로 넘어가기 전 요약.
    case planSummary(URL)
    case reviewing
    /// 앱이 셸로 실행을 준비하는 화면. 실행 폴더는 준비가 끝난 뒤에 만든다.
    case preparing(runName: String)
    case running(runDir: URL)
    case results(runDir: URL)
}

/// 계획 쓰기 시작 화면에 보이는 기준 소스.
struct PlanSourceInfo: Equatable {
    let path: String
    let branch: String?
    let commit: String?
    /// nil이면 git status를 읽지 못했다.
    let isDirty: Bool?
    /// 소스 폴더가 .cache/repos면 계획을 쓸 때 project.yaml 브랜치 최신으로 맞춘다.
    let isCache: Bool
}

/// 계획을 다 쓴 뒤 보이는 요약.
struct PlanSummaryInfo {
    struct FileChange: Identifiable {
        let name: String
        let added: [String]
        let removed: [String]
        var id: String { name }
    }

    let planURL: URL
    let automatic: Int
    let human: Int
    let manual: Int
    let pilots: [String]
    let changes: [FileChange]
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
    @ObservationIgnored @AppStorage("adbPath") var adbPath = ""
    @ObservationIgnored @AppStorage("claudePath") var claudePath = ""

    var workspace: Workspace?
    var projects: [ProjectRef] = []
    var selectedProject: ProjectRef?
    var selectedPlan: PlanDocument?
    var selectedRun: URL?
    var phase: AppPhase = .empty
    var activeRun: ActiveRun?
    var activeStage: Stage?
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
    var stageWasStopped = false
    var stageFailed = false
    /// 단계 기록 화면에 보일 기록. 없으면 이 프로젝트에서 앱으로 돌린 적이 없음.
    var viewedStageRecord: StageRecord?
    /// 계획 쓰기 시작 화면의 범위 입력.
    var planScope = ""
    /// 결정 필요에 다는 답 입력.
    var planDecisionAnswer = ""
    var planSummary: PlanSummaryInfo?
    var isStageCancelConfirmationPresented = false
    var isUnsavedEditsConfirmationPresented = false
    /// 확인 창에서 "저장하고 이동"·"버리고 이동"을 고르면 할 일.
    @ObservationIgnored private var pendingNavigation: (() -> Void)?
    @ObservationIgnored private var stageToCancel: Stage?
    var rateLimits: ClaudeRateLimits?
    var runEvents: [RunEvent] = []
    var runStates: [String: ScenarioRunState] = [:]
    var runUsage = Usage(llm_calls: 0, prompt_tokens: 0, completion_tokens: 0)
    var runDeviceSerial = ""
    var runServer = ""
    /// 준비 화면에 보일 항목 상태·로그·결과.
    var prepareItems: [PrepareStep: PrepareItemState] = [:]
    var prepareLogTail = ""
    var prepareResult: PrepareResult?
    var prepareStartedAt: Date?
    var runScenarioCalls: [String: Int] = [:]
    var runStartedAt: [String: Date] = [:]
    var runFinishedAt: [String: Date] = [:]
    var stallSignals: [String: StallSignal] = [:]
    var pollFailureReasons: [String: String] = [:]
    var traceLogMissingScenarioIDs: Set<String> = []
    var adbUnavailableScenarioIDs: Set<String> = []
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
    var isJudgeLogPresented = false
    var pendingCommitFiles: [String] = []
    var isCommitConfirmationPresented = false

    @ObservationIgnored private var artemisLogReader: LogTailReader?
    @ObservationIgnored private var claudeRunner: ClaudeRunner?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var loadErrorShownRuns: Set<String> = []
    @ObservationIgnored private var reviewSaveTask: Task<Void, Never>?
    @ObservationIgnored private var runOrchestrator: RunOrchestrator?
    @ObservationIgnored private var prepareCoordinator: PrepareCoordinator?
    /// 실행 루프(orchestrator.start·retry)를 도는 Task. 앱을 끝낼 때 취소해 초기화 중인 셸 명령도 끊는다.
    @ObservationIgnored private var runOperationTask: Task<Bool, Never>?
    @ObservationIgnored private var prepareContext: (input: PrepareInput, approval: Approval, plannedRunDir: URL)?
    /// 앱이 띄운 Artemis·테스트 서버를 띄우는 순간부터 기억한다. 앱이 끝날 때 함께 끝낸다.
    @ObservationIgnored private let processLauncher = TrackingProcessLauncher()
    @ObservationIgnored private var lockNotified = false
    @ObservationIgnored private var runOrchestratorContext: ActiveRun?
    @ObservationIgnored private var stageResultIsError: Bool?
    @ObservationIgnored private var stageResultSummary = ""
    /// 가리기 전 단계 출력. 계획 경로 찾기 같은 내부 해석에만 쓰고 화면에는 stageLog(가린 것)를 보인다.
    @ObservationIgnored private var stageRawLog = ""
    @ObservationIgnored private var stageSecretValues: [String] = []
    @ObservationIgnored private let stageRecordStore = StageRecordStore.standard
    /// 지금 도는 등록·계획 단계의 기록. 출력이 늘면 잠시 모았다가 저장한다.
    @ObservationIgnored private var liveStageRecord: StageRecord?
    @ObservationIgnored private var stageRecordSaveTask: Task<Void, Never>?
    /// showPastRun이 진행 화면 상태를 지난 실행 값으로 바꿔 놓았으면 그 실행.
    @ObservationIgnored private var displayedPastRun: URL?
    /// 이번 계획 쓰기에 넘긴 답. 결정 필요에 다시 답하면 이어 붙인다.
    @ObservationIgnored private var planAnswers: [String] = []
    /// 계획 쓰기 전 knowledge.md·project.yaml 내용. 요약에서 바뀐 줄을 보인다.
    @ObservationIgnored private var planSnapshot: [String: String] = [:]
    /// 실행 중인 프로젝트의 .env 값. Artemis 로그를 화면에 보이기 전에 가린다.
    @ObservationIgnored private var runSecretValues: [String] = []

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
                withUnsavedEditsCheck { [self] in selectProject(project) }
                return
            }
            withUnsavedEditsCheck { [self] in
                pendingSourceURL = url
                isCategoryConfirmationPresented = true
            }
        } catch {
            show(error)
        }
    }

    func registerPendingSource(as category: ProjectCategory) async {
        guard let source = pendingSourceURL else { return }
        isCategoryConfirmationPresented = false
        pendingSourceURL = nil
        let record = StageRecord(
            stage: .register,
            key: StageRecord.registerKey(projectName: source.lastPathComponent),
            sourcePath: source.path,
            category: category,
            startedAt: .now,
            status: .running
        )
        let succeeded = await runStage(
            .register,
            prompt: StagePrompt.register(sourcePath: source.path, category: category),
            record: record
        )
        guard succeeded, let workspace else { return }
        do {
            reloadProjects()
            guard let project = try workspace.project(matchingSource: source) else {
                notice = AppNotice(title: "등록 결과를 찾지 못했어요", message: "프로젝트 등록 결과를 확인해 주세요.")
                return
            }
            // 프로젝트 이름이 소스 폴더 이름과 다르면 프로젝트 이름으로도 기록을 남겨 등록 단계 화면에서 찾게 한다.
            let projectKey = StageRecord.registerKey(projectName: project.name)
            if projectKey != record.key,
               var saved = stageRecordStore.load(stage: .register, key: record.key, isLive: false) {
                saved.key = projectKey
                try? stageRecordStore.save(saved)
            }
            // 이전에 고른 다른 프로젝트의 계획·실행이 남지 않게 새 프로젝트로 바꾼다.
            selectProject(project)
            // 등록이 끝나면 바로 쓰지 않고 범위를 정하는 시작 화면으로 간다.
            showPlanSetup(for: project)
        } catch {
            show(error)
        }
    }

    /// + 버튼·"새 계획 쓰기": 바로 쓰지 않고 시작 화면을 연다.
    func showPlanSetup(for project: ProjectRef? = nil) {
        guard !hasActiveExecution else { return }
        if let project, project.id != selectedProject?.id { selectProject(project) }
        guard selectedProject != nil else { return }
        planScope = ""
        phase = .planSetup
    }

    func cancelPlanSetup() {
        phase = selectedPlan == nil ? .empty : .reviewing
    }

    /// 시작 화면의 "계획 작성하기".
    func startPlanFromSetup() async {
        await generatePlan(scope: planScope, answers: [])
    }

    /// 결정 필요에 답을 달아 같은 범위로 다시 쓴다.
    func answerPlanDecision() async {
        let answer = planDecisionAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decision = stageDecision, !answer.isEmpty else { return }
        let question = decision.replacingOccurrences(of: "결정 필요:", with: "").trimmingCharacters(in: .whitespaces)
        planDecisionAnswer = ""
        await generatePlan(scope: planScope, answers: planAnswers + ["\(question) → \(answer)"])
    }

    func generatePlan(scope: String? = nil, answers: [String] = []) async {
        guard let project = selectedProject else { return }
        planAnswers = answers
        // 답을 달아 다시 쓸 때는 처음 시작할 때의 내용을 기준으로 둬야 앞 실행의 변경도 요약에 나온다.
        if answers.isEmpty {
            planSnapshot = Self.planSnapshotFiles.reduce(into: [:]) { snapshot, name in
                snapshot[name] = (try? String(contentsOf: project.dir.appending(path: name), encoding: .utf8)) ?? ""
            }
        }
        let succeeded = await runStage(
            .plan,
            prompt: StagePrompt.plan(project: project, scope: scope, answers: answers),
            record: StageRecord(stage: .plan, key: StageRecord.planKey(project: project), startedAt: .now, status: .running)
        )
        // 결정이 필요해 멈췄으면 단계 화면에 남아 답을 받는다.
        guard succeeded, stageDecision == nil else { return }
        do {
            guard let planURL = try planURLFromStageOutput(for: project) else {
                notice = AppNotice(title: "계획 파일을 찾지 못했어요", message: "Claude Code 출력과 plans 폴더를 확인해 주세요.")
                return
            }
            let plan = try PlanDocument.load(planURL)
            planSummary = summary(of: plan, project: project)
            phase = .planSummary(planURL)
        } catch {
            show(error)
        }
    }

    /// 요약 화면의 "목록 확인으로".
    func openSummarizedPlan() {
        guard case .planSummary(let url) = phase else { return }
        do {
            try selectPlan(at: url)
        } catch {
            show(error)
        }
    }

    /// 시작 화면에 보일 기준 소스. project.local.yaml의 source_path, 없으면 .cache/repos/<project>.
    func planSourceInfo(for project: ProjectRef) async -> PlanSourceInfo? {
        guard let workspace else { return nil }
        let cache = workspace.root.appending(path: ".cache/repos/\(project.name)").path
        let path = project.sourcePath.map(expandedPath) ?? cache
        guard FileManager.default.fileExists(atPath: path) else {
            // source_path를 정했는데 폴더가 없으면 받지 않으므로 경로만 알린다.
            return project.sourcePath == nil
                ? nil
                : PlanSourceInfo(path: path, branch: nil, commit: nil, isDirty: nil, isCache: false)
        }
        let shell = ProcessShellRunner()
        func git(_ args: [String]) async -> String? {
            guard let result = try? await shell.run("/usr/bin/git", ["-C", path] + args), result.status == 0 else { return nil }
            return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"])
        let commit = await git(["rev-parse", "--short", "HEAD"])
        let status = await git(["status", "--porcelain"])
        return PlanSourceInfo(
            path: path,
            branch: branch,
            commit: commit,
            isDirty: status.map { !$0.isEmpty },
            isCache: project.sourcePath == nil
        )
    }

    /// 이 프로젝트의 가장 최근 계획(시작 화면에서 소스 커밋과 비교한다).
    func latestPlan(for project: ProjectRef) -> PlanDocument? {
        plans(for: project).first.flatMap { try? PlanDocument.load($0) }
    }

    private static let planSnapshotFiles = ["knowledge.md", "project.yaml"]

    private func summary(of plan: PlanDocument, project: ProjectRef) -> PlanSummaryInfo {
        let changes = Self.planSnapshotFiles.compactMap { name -> PlanSummaryInfo.FileChange? in
            let after = (try? String(contentsOf: project.dir.appending(path: name), encoding: .utf8)) ?? ""
            let diff = LineChanges.compare(before: planSnapshot[name] ?? "", after: after)
            guard !diff.added.isEmpty || !diff.removed.isEmpty else { return nil }
            return PlanSummaryInfo.FileChange(name: name, added: diff.added, removed: diff.removed)
        }
        let titles = Dictionary(plan.scenarios.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return PlanSummaryInfo(
            planURL: plan.url,
            automatic: plan.scenarios.count { $0.grade == .A },
            human: plan.scenarios.count { $0.grade == .B },
            manual: manualCount(of: plan),
            pilots: plan.pilotIDs.map { id in titles[id].map { "\(id) · \($0)" } ?? id },
            changes: changes
        )
    }

    private func manualCount(of plan: PlanDocument) -> Int {
        let manual = plan.scenarios.count { $0.grade == .C }
        if manual > 0 { return manual }
        guard let range = plan.text.range(of: #"(?ms)^###?\s+4\.8\s+수동\(C\).*?(?=^##\s|\z)"#, options: .regularExpression) else {
            return 0
        }
        return String(plan.text[range]).components(separatedBy: .newlines).count {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
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
            showEmptyResults(for: url, error: error)
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

    @discardableResult
    func savePlan() -> Bool {
        guard let workspace, let project = selectedProject, let plan = selectedPlan else { return false }
        do {
            let hasRuns = try !workspace.runs(of: project, plan: plan.url).isEmpty
            guard let target = PlanSaveTarget.resolve(plan: plan.url, hasRuns: hasRuns, now: .now) else {
                notice = AppNotice(title: "저장할 수 없어요", message: "같은 이름의 계획 파일이 이미 있어요. 잠시 뒤 다시 저장해 주세요.")
                return false
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
            return true
        } catch {
            show(error)
            return false
        }
    }

    func presentApproval() {
        if !editedScenarioIDs.isEmpty, !savePlan() {
            return
        }
        isApprovalPresented = true
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
        guard workspace != nil, let project = selectedProject, let plan = selectedPlan else {
            notice = AppNotice(title: "실행할 수 없어요", message: "사이드바에서 프로젝트와 계획을 다시 골라 주세요.")
            return
        }
        isApprovalPresented = false
        Notifier.requestAuthorization()
        let scenarios = orderedScenarios.filter { approval.scenarioIDs.contains($0.id) }
        let plannedRunDir = plannedRunDirectory(project: project, plan: plan.url)
        guard let input = prepareInput(
            project: project,
            plan: plan,
            scenarios: scenarios,
            serial: approval.deviceSerial,
            server: approval.server,
            loginRole: approval.loginRole,
            forceRebuild: approval.forceRebuild,
            runName: plannedRunDir.lastPathComponent
        ) else {
            notice = AppNotice(title: "실행할 수 없어요", message: "adb를 찾지 못했어요. 설정의 adb 경로를 확인해 주세요.")
            return
        }
        // 실행 폴더는 아직 없지만 실행 중으로 보이게(사이드바·단계 잠금) 계획한 경로로 둔다.
        activeRun = ActiveRun(runDir: plannedRunDir, project: project, plan: plan, scenarioIDs: approval.scenarioIDs)
        let coordinator = PrepareCoordinator(
            input: input,
            api: ArtemisClient(base: URL(string: artemisURL) ?? URL(string: "http://127.0.0.1:8100")!),
            shell: ProcessShellRunner(),
            health: URLSessionHealthChecker(),
            launcher: processLauncher
        )
        prepareCoordinator = coordinator
        prepareContext = (input, approval, plannedRunDir)
        prepareItems = [:]
        prepareLogTail = ""
        prepareResult = nil
        prepareStartedAt = .now
        lockNotified = false
        runDeviceSerial = approval.deviceSerial
        runServer = approval.server
        phase = .preparing(runName: plannedRunDir.lastPathComponent)
        await consumePrepare(coordinator, starting: { await coordinator.run() })
    }

    /// 준비 화면의 "다시 시도". 실패한 항목부터 다시 한다.
    func retryPrepare() async {
        guard let coordinator = prepareCoordinator else { return }
        prepareResult = nil
        await consumePrepare(coordinator, starting: { await coordinator.retryFromFailed() })
    }

    /// 준비 화면의 "목록으로"·"준비 취소". 실행 폴더는 만들지 않았으므로 지울 것이 없다.
    func cancelPrepare() async {
        // 결과가 이미 왔어도(실패 뒤 "목록으로") 취소는 해 둔다. 끝난 코디네이터에는 영향이 없다.
        if let coordinator = prepareCoordinator {
            await coordinator.cancel()
        }
        prepareCoordinator = nil
        prepareContext = nil
        activeRun = nil
        phase = selectedPlan == nil ? .empty : .reviewing
    }

    func recheckPrepareDevice() async {
        await prepareCoordinator?.recheckDevice()
    }

    /// 승인 시트의 준비 점검. Artemis가 꺼져 있고 이 맥이면 띄운다(스펙 5.3).
    func preflight(serial: String, server: String, loginRole: String?, scenarioIDs: [String]) async -> [PrepareStep: PrepareItemState] {
        guard let project = selectedProject, let plan = selectedPlan,
              let input = prepareInput(
                  project: project,
                  plan: plan,
                  scenarios: orderedScenarios.filter { scenarioIDs.contains($0.id) },
                  serial: serial,
                  server: server,
                  loginRole: loginRole,
                  forceRebuild: false,
                  runName: "preflight"
              )
        else { return [:] }
        let result = await PrepareCoordinator.preflight(
            input: input,
            api: ArtemisClient(base: URL(string: artemisURL) ?? URL(string: "http://127.0.0.1:8100")!),
            shell: ProcessShellRunner(),
            health: URLSessionHealthChecker(),
            launcher: processLauncher
        )
        return result.items
    }

    /// 이 프로젝트의 project.yaml 설정.
    func projectConfig(for project: ProjectRef) -> ProjectConfig {
        ProjectConfig.parse((try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? "")
    }

    /// 계획을 쓸 소스: project.local.yaml의 source_path, 없으면 .cache/repos/<project>.
    func sourceDirectory(for project: ProjectRef) -> URL? {
        guard let workspace else { return nil }
        return URL(fileURLWithPath: project.sourcePath.map(expandedPath)
            ?? workspace.root.appending(path: ".cache/repos/\(project.name)").path)
    }

    private func prepareInput(
        project: ProjectRef,
        plan: PlanDocument,
        scenarios: [Scenario],
        serial: String,
        server: String,
        loginRole: String?,
        forceRebuild: Bool,
        runName: String
    ) -> PrepareInput? {
        guard let workspace, let adb = resolvedADBPath(), let sourceDir = sourceDirectory(for: project) else { return nil }
        return PrepareInput(
            projectDir: project.dir,
            sourceDir: sourceDir,
            config: projectConfig(for: project),
            serverName: server,
            serial: serial,
            scenarios: scenarios,
            plan: plan,
            loginRole: loginRole,
            forceRebuild: forceRebuild,
            artemisURL: URL(string: artemisURL) ?? URL(string: "http://127.0.0.1:8100")!,
            artemisHome: URL(fileURLWithPath: expandedPath(artemisHome)),
            tracesDir: artemisTracesDir.isEmpty ? nil : URL(fileURLWithPath: expandedPath(artemisTracesDir)),
            adbPath: adb,
            loginScript: workspace.root.appending(path: "tools/android-login.sh"),
            logURL: PrepareLog.url(project: project, runName: runName)
        )
    }

    private func consumePrepare(_ coordinator: PrepareCoordinator, starting operation: @escaping @Sendable () async -> Void) async {
        let operationTask = Task { await operation() }
        var finished: PrepareResult?
        for await event in coordinator.events {
            // 취소한 뒤 새 준비를 시작했으면 이전 준비의 이벤트는 버린다.
            guard prepareCoordinator === coordinator else {
                if case .finished = event { break }
                continue
            }
            switch event {
            case .item(let step, let state):
                prepareItems[step] = state
                if step == .device, case .waitingForHuman(let reason) = state, !lockNotified {
                    lockNotified = true
                    // 잠금만이 아니라 연결·Wi-Fi일 수도 있으니 이유를 그대로 알린다.
                    Notifier.send(title: "기기를 확인해 주세요", body: "\(reason) — 고치면 준비를 이어서 해요.")
                }
            case .log(let line):
                let lines = (prepareLogTail.isEmpty ? [] : prepareLogTail.components(separatedBy: "\n")) + [line]
                prepareLogTail = lines.suffix(200).joined(separator: "\n")
            case .finished(let result):
                finished = result
            }
            if finished != nil { break }
        }
        await operationTask.value
        guard prepareCoordinator === coordinator else { return }
        guard let result = finished else { return }
        prepareResult = result
        guard !isTerminating else {
            activeRun = nil
            phase = .empty
            return
        }
        // 취소는 cancelPrepare가 화면을 정리한다. 실패면 준비 화면에 남아 "다시 시도"를 기다린다.
        guard result.succeeded else { return }
        await beginRunAfterPrepare(result)
    }

    /// 준비가 끝나면 실행 폴더를 만들고(qa-run 3단계) 로그를 옮긴 뒤 실행 루프로 넘어간다.
    private func beginRunAfterPrepare(_ result: PrepareResult) async {
        guard let workspace, let context = prepareContext, let project = selectedProject, let plan = selectedPlan else { return }
        do {
            let runDir = try createRunDirectory(planned: context.plannedRunDir, workspace: workspace, project: project, plan: plan.url)
            try? PrepareLog(url: context.input.logURL, secrets: []).move(toRunDir: runDir)
            let activeContext = ActiveRun(runDir: runDir, project: project, plan: plan, scenarioIDs: context.approval.scenarioIDs)
            activeRun = activeContext
            selectedRun = runDir
            let scenarios = context.input.scenarios
            let roles = Workspace.accountRoles(projectYAML: (try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? "")
            let loginPlan = LoginPlan.make(scenarios: scenarios, roles: roles, chosenRole: context.approval.loginRole)
            var loginBefore: String?
            if case .beforeScenario(let id) = loginPlan.when { loginBefore = id }
            let config = context.input.config
            let reset = config.package.flatMap { package in
                config.launch.map { launch in
                    ResetContext(
                        package: package,
                        launch: launch,
                        permissions: config.permissions,
                        loginScript: context.input.loginScript,
                        envURL: project.dir.appending(path: ".env"),
                        roles: roles,
                        chosenRole: context.approval.loginRole,
                        loginBefore: loginBefore,
                        secrets: SecretKeys.values(
                            envURL: project.dir.appending(path: ".env"),
                            accountKeys: Set(Workspace.accountEnvKeys(projectYAML: (try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? ""))
                        )
                    )
                }
            }
            resetRunState(for: scenarios)
            displayedPastRun = nil
            let orchestrator = makeOrchestrator(
                runDir: runDir,
                plan: plan,
                scenarios: scenarios,
                deviceSerial: context.approval.deviceSerial,
                server: context.approval.server,
                reset: reset,
                prepare: result
            )
            runOrchestrator = orchestrator
            runOrchestratorContext = activeContext
            prepareCoordinator = nil
            prepareContext = nil
            phase = .running(runDir: runDir)
            await consumeRun(
                orchestrator,
                starting: {
                    await orchestrator.start()
                    return true
                },
                runDir: runDir
            )
        } catch {
            activeRun = nil
            phase = .reviewing
            show(error)
        }
    }

    func stopCurrentAsHeld() async {
        stallSignals.removeValue(forKey: currentRunningScenarioID ?? "")
        await runOrchestrator?.stopCurrentAsHeld()
    }

    func stopAll() async {
        if prepareCoordinator != nil, case .preparing = phase {
            await cancelPrepare()
        }
        await runOrchestrator?.stopAll()
        // "전체 중지…" 확인 창을 연 사이에 판정 단계로 넘어갔으면 판정도 사용자 중지로 끝낸다.
        if activeStage != nil { stageWasStopped = true }
        claudeRunner?.cancel()
    }

    func stopAllForTermination() async {
        isTerminating = true
        await stopAll()
        // 실행 중 초기화(pm clear·pm grant·로그인) 명령은 stopAll로 멈추지 않으니 Task를 취소해 끊는다.
        runOperationTask?.cancel()
        while hasActiveExecution {
            try? await Task.sleep(for: .milliseconds(100))
        }
        claudeRunner?.cancel()
        await terminateOwnedProcesses()
    }

    /// 앱이 띄운 Artemis·테스트 서버가 있는지(종료할 때 끝낼 것).
    var hasOwnedProcesses: Bool { processLauncher.processes.contains { $0.isRunning } }

    /// 앱이 띄운 Artemis·테스트 서버를 함께 끝낸다. 터미널에서 띄운 것은 건드리지 않는다.
    func terminateOwnedProcesses() async {
        for process in processLauncher.processes {
            await process.terminate()
            processLauncher.forget(process)
        }
    }

    func keepWaiting(id: String) async {
        stallSignals.removeValue(forKey: id)
        await runOrchestrator?.rearmStall(id: id)
    }

    func refreshCurrentArtemisLog() {
        // 지난 실행 기록을 볼 때는 로그를 띄우지 않는다(가릴 .env 값을 이 실행 기준으로 읽지 않았다).
        guard activeRun != nil, let sessionID = currentSessionID else {
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
        if artemisLogReader?.url != url {
            artemisLogReader = LogTailReader(url: url)
        }
        guard artemisLogReader?.read() == true, let reader = artemisLogReader else {
            artemisLog = "로그를 기다리고 있어요."
            return
        }
        // 앞을 잘라 낸 줄과 아직 쓰는 중인 마지막 줄에 걸친 값 조각도 가린다.
        artemisLog = SecretRedactor.redact(reader.tail, values: runSecretValues, truncationMarker: LogTailReader.truncationMarker)
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
        review.correctCause(cause, for: result)
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

    /// 결과 화면에서 이 시나리오가 수정 요청 md에 들어갈 모양.
    func fixRequestSection(for result: ScenarioResult) -> String {
        guard let selectedRun else { return "" }
        return FixRequestRenderer.section(
            result: result,
            entry: review.entry(for: result),
            plan: selectedPlan,
            runDirRelative: workspace.map { relativePath(selectedRun, from: $0.root) } ?? selectedRun.path
        )
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
            let head = try await workspaceHead(workspace)
            guard head != .detached else {
                notice = detachedHeadNotice
                return
            }
            if case .branch(let branch) = head, !head.isMain {
                notice = AppNotice(
                    title: "커밋할 수 없어요",
                    message: "main 브랜치가 아니라 커밋하지 않았어요 (현재: \(branch)). 메인 작업 트리에서 main으로 바꾼 뒤 다시 눌러 주세요."
                )
                return
            }
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
            let head = try await workspaceHead(workspace)
            guard head != .detached else {
                notice = detachedHeadNotice
                return
            }
            // 확인 창이 열린 사이 브랜치가 바뀌었을 수 있으니 add 전에 다시 본다.
            if case .branch(let branch) = head, !head.isMain {
                pendingCommitFiles = []
                notice = AppNotice(
                    title: "커밋할 수 없어요",
                    message: "main 브랜치가 아니라 커밋하지 않았어요 (현재: \(branch)). 메인 작업 트리에서 main으로 바꾼 뒤 다시 눌러 주세요."
                )
                return
            }
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
                ["-C", workspace.root.path, "commit", "-m", message, "--"] + pendingCommitFiles,
                timeout: .seconds(60)
            )
            guard commit.status == 0 else { throw shellError(commit.out) }
            let push: (status: Int32, out: String)
            do {
                let remoteConfig = try await shell.run(
                    "/usr/bin/git",
                    ["-C", workspace.root.path, "config", "branch.main.remote"]
                )
                let configuredRemote = remoteConfig.out.trimmingCharacters(in: .whitespacesAndNewlines)
                let remote = remoteConfig.status == 0 && !configuredRemote.isEmpty ? configuredRemote : "origin"
                push = try await shell.run(
                    "/usr/bin/git",
                    ["-C", workspace.root.path, "push", remote, "HEAD:main"],
                    timeout: .seconds(60)
                )
            } catch ShellRunnerError.timedOut {
                throw shellError("git push가 60초 안에 끝나지 않아 중단했어요. 커밋은 로컬에 남아 있어요.")
            }
            guard push.status == 0 else { throw shellError(push.out) }
            pendingCommitFiles = []
            notice = AppNotice(title: "커밋했어요", message: message)
        } catch {
            show(error)
        }
    }

    func retryScenario(_ id: String) async {
        guard let orchestrator = runOrchestrator,
              let context = runOrchestratorContext,
              selectedRun?.standardizedFileURL == context.runDir.standardizedFileURL,
              orchestrator.runDir.standardizedFileURL == context.runDir.standardizedFileURL
        else {
            notice = AppNotice(title: "다시 돌릴 수 없어요", message: "이 앱 실행 중에 만든 결과에서만 다시 돌릴 수 있어요.")
            return
        }
        // 다른 지난 실행을 보느라 진행 상태가 바뀌었으면 이 실행의 run-state.json으로 되돌린다.
        if let shown = displayedPastRun, shown.standardizedFileURL != context.runDir.standardizedFileURL,
           let data = try? Data(contentsOf: context.runDir.appending(path: "run-state.json")),
           let state = try? JSONDecoder().decode(RunStateFile.self, from: data) {
            applyRunState(state)
        }
        displayedPastRun = nil
        activeRun = context
        phase = .running(runDir: context.runDir)
        await consumeRun(
            orchestrator,
            starting: { await orchestrator.retry(id: id) },
            runDir: context.runDir
        )
    }

    func canRetry(in runDir: URL) -> Bool {
        guard let orchestrator = runOrchestrator else { return false }
        return orchestrator.runDir.standardizedFileURL == runDir.standardizedFileURL
    }

    func retryJudgment() async {
        guard let selectedRun, let context = runContext(for: selectedRun) else { return }
        activeRun = context
        let started = Date.now
        let succeeded = await runStage(
            .judge,
            prompt: StagePrompt.judge(
                project: context.project,
                plan: workspace.map { relativePath(context.plan.url, from: $0.root) } ?? context.plan.url.path,
                runDir: workspace.map { relativePath(context.runDir, from: $0.root) } ?? context.runDir.path
            ),
            record: StageRecord(stage: .judge, key: StageRecord.judgeKey(project: context.project, planName: context.runDir.deletingLastPathComponent().lastPathComponent, runName: context.runDir.lastPathComponent), startedAt: .now, status: .running)
        )
        judgeDuration = Date.now.timeIntervalSince(started)
        if succeeded {
            do {
                try loadResults(from: context.runDir)
            } catch {
                loadErrorShownRuns.remove(context.runDir.standardizedFileURL.path)
                showEmptyResults(for: context.runDir, error: error)
            }
        } else {
            clearResults()
        }
        activeRun = nil
    }

    /// 이 실행의 판정 기록. 앱에서 판정했을 때만 있다.
    func judgeRecord(for runDir: URL) -> StageRecord? {
        guard let project = projects.first(where: {
            runDir.standardizedFileURL.path.hasPrefix($0.dir.standardizedFileURL.path + "/")
        }) else { return nil }
        let isLive = activeStage == .judge
            && activeRun?.runDir.standardizedFileURL == runDir.standardizedFileURL
        return stageRecordStore.load(
            stage: .judge,
            key: StageRecord.judgeKey(project: project, planName: runDir.deletingLastPathComponent().lastPathComponent, runName: runDir.lastPathComponent),
            isLive: isLive
        )
    }

    // MARK: 저장 안 한 수정 보호

    /// 저장하지 않은 수정이 있으면 확인 창을 띄우고, 없으면 바로 action을 한다.
    private func withUnsavedEditsCheck(_ action: @escaping () -> Void) {
        guard !editedScenarioIDs.isEmpty else {
            action()
            return
        }
        pendingNavigation = action
        isUnsavedEditsConfirmationPresented = true
    }

    /// 확인 창의 "저장하고 이동". 저장에 실패하면(알림이 뜬다) 이동하지 않는다.
    func saveEditsThenNavigate() {
        let pending = pendingNavigation
        pendingNavigation = nil
        guard savePlan(), let pending else { return }
        pending()
    }

    /// 확인 창의 "버리고 이동". 파일을 다시 읽어 고친 goal·통과 조건을 되돌린다(순서·포함은 그대로).
    func discardEditsThenNavigate() {
        editedScenarioIDs = []
        if let url = selectedPlan?.url, let saved = try? PlanDocument.load(url) {
            let positions = Dictionary(uniqueKeysWithValues: orderedScenarios.enumerated().map { ($0.element.id, $0.offset) })
            selectedPlan = saved
            orderedScenarios = saved.scenarios.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
        }
        let pending = pendingNavigation
        pendingNavigation = nil
        pending?()
    }

    func cancelNavigation() {
        pendingNavigation = nil
    }

    func requestSelectProject(_ project: ProjectRef) {
        withUnsavedEditsCheck { [self] in selectProject(project) }
    }

    func requestSelectPlan(at url: URL) {
        let isCurrent = url.standardizedFileURL == selectedPlan?.url.standardizedFileURL
        withUnsavedEditsCheck { [self] in
            let target = isCurrent ? (selectedPlan?.url ?? url) : url
            do {
                try selectPlan(at: target)
            } catch {
                notice = AppNotice(title: "계획을 열지 못했어요", message: error.localizedDescription)
            }
        }
    }

    func requestPlanSetup(for project: ProjectRef? = nil) {
        withUnsavedEditsCheck { [self] in showPlanSetup(for: project) }
    }

    /// 취소 확인 창을 연 단계. 창이 떠 있는 사이 다음 단계로 넘어갔으면 그 단계는 취소하지 않는다.
    func confirmStageCancel() {
        stageToCancel = activeStage
        isStageCancelConfirmationPresented = true
    }

    func cancelConfirmedStage() {
        guard let stageToCancel, stageToCancel == activeStage else { return }
        cancelStage()
    }

    func cancelStage() {
        stageWasStopped = true
        claudeRunner?.cancel()
    }

    func returnFromStage() {
        phase = selectedPlan == nil ? .empty : .reviewing
    }

    // MARK: 단계 표시에서 단계 열기

    /// 실행 단계·결과 단계가 보여 줄 실행: 고른 실행, 없으면 고른 계획의 가장 최근 실행.
    var stepRun: URL? {
        if let selectedRun { return selectedRun }
        guard let project = selectedProject, let plan = selectedPlan?.url else { return nil }
        return runs(for: project, plan: plan).first
    }

    /// 지금 누를 수 있는 단계. 툴바를 그릴 때 한 번만 계산한다.
    /// 실행·단계가 도는 중에는 사이드바처럼 그 진행 화면으로만 갈 수 있다.
    func availableSteps() -> Set<PipelineStep> {
        if let activeStage {
            switch activeStage {
            case .register: return [.register]
            case .plan: return [.plan]
            case .judge: return [.run]
            }
        }
        if activeRun != nil { return [.run] }
        var steps: Set<PipelineStep> = []
        if selectedProject != nil || stageRecordStore.latest(stage: .register) != nil { steps.insert(.register) }
        if selectedProject != nil { steps.insert(.plan) }
        if selectedPlan != nil { steps.insert(.review) }
        if let run = stepRun {
            steps.insert(.run)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: run.appending(path: "results.json").path)
                || fileManager.fileExists(atPath: run.appending(path: "summary.md").path) {
                steps.insert(.results)
            }
        }
        return steps
    }

    /// 고른 프로젝트·계획·실행 기준으로 이미 끝낸 단계. 어느 단계 화면을 보든 같다.
    /// 지금 도는 단계와 그 뒤 단계는 끝나지 않은 것으로 본다.
    func completedSteps() -> Set<PipelineStep> {
        var steps: Set<PipelineStep> = []
        if selectedProject != nil { steps.insert(.register) }
        if selectedPlan != nil { steps.insert(.plan) }
        if let run = stepRun {
            steps.insert(.review)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: run.appending(path: "results.json").path)
                || fileManager.fileExists(atPath: run.appending(path: "summary.md").path) {
                steps.formUnion([.run, .results])
            }
        }
        let ongoing: [PipelineStep]
        switch activeStage {
        case .register: ongoing = [.register, .plan, .review, .run, .results]
        case .plan: ongoing = [.plan, .review, .run, .results]
        // 판정 중에는 실행 루프가 끝났지만 결과 파일은 판정이 쓰므로 실행을 직접 체크한다.
        case .judge: steps.insert(.run); ongoing = [.results]
        case nil: ongoing = activeRun != nil ? [.run, .results] : []
        }
        return steps.subtracting(ongoing)
    }

    func showStep(_ step: PipelineStep) {
        guard availableSteps().contains(step) else { return }
        switch step {
        case .register, .plan:
            let stage: Stage = step == .register ? .register : .plan
            if activeStage == stage {
                phase = .stage(stage)
            } else {
                viewedStageRecord = stageRecord(stage)
                phase = .stageRecord(stage)
            }
        case .review:
            phase = .reviewing
        case .run:
            if case .preparing = phase {
                return
            } else if prepareCoordinator != nil, let activeRun {
                phase = .preparing(runName: activeRun.runDir.lastPathComponent)
            } else if let activeStage, activeStage == .judge {
                phase = .stage(activeStage)
            } else if let activeRun {
                phase = .running(runDir: activeRun.runDir)
            } else if let run = stepRun {
                showPastRun(run)
            }
        case .results:
            guard let run = stepRun else { return }
            // 이미 그 결과를 보고 있으면 고른 시나리오를 되돌리지 않는다.
            if case .results(let shown) = phase, shown.standardizedFileURL == run.standardizedFileURL { return }
            selectRun(run)
        }
    }

    /// 단계 기록 화면의 "다시 시작"·"새 계획 쓰기".
    func restartStage(from record: StageRecord?) async {
        guard !hasActiveExecution else { return }
        if record?.stage == .register, let path = record?.sourcePath, let category = record?.category {
            withUnsavedEditsCheck { [self] in
                pendingSourceURL = URL(fileURLWithPath: path)
                Task { await registerPendingSource(as: category) }
            }
        } else {
            requestPlanSetup()
        }
    }

    func newPlan(for project: ProjectRef) {
        requestPlanSetup(for: project)
    }

    /// 지금 돌지 않는 단계의 기록(showStep은 도는 단계를 진행 화면으로 보낸다).
    /// 프로젝트를 고르지 않았으면 가장 최근 등록 기록 — 등록이 끊겨 프로젝트가 없을 때도 다시 시작할 수 있게.
    private func stageRecord(_ stage: Stage) -> StageRecord? {
        guard let project = selectedProject else {
            return stage == .register ? stageRecordStore.latest(stage: .register) : nil
        }
        let key = stage == .register ? StageRecord.registerKey(projectName: project.name) : StageRecord.planKey(project: project)
        return stageRecordStore.load(stage: stage, key: key, isLive: false)
    }

    /// 끝난 실행의 진행 화면을 run-state.json으로 다시 그린다. 진행 중인 실행이 있으면 건드리지 않는다.
    private func showPastRun(_ run: URL) {
        guard activeRun == nil,
              let data = try? Data(contentsOf: run.appending(path: "run-state.json")),
              let state = try? JSONDecoder().decode(RunStateFile.self, from: data)
        else {
            selectRun(run)
            return
        }
        applyRunState(state)
        displayedPastRun = run
        selectedRun = run
        phase = .running(runDir: run)
    }

    /// run-state.json 값으로 진행 화면 상태를 채운다. 진행 중으로 남은 시나리오는 앱이 끝나며 끊긴 것이다.
    private func applyRunState(_ state: RunStateFile) {
        resetRunState(for: [])
        runStates = state.states.mapValues { value in
            if case .running = value { return .held(reason: "앱이 끝나 중단됨") }
            return value
        }
        runUsage = state.usage
        runDeviceSerial = state.deviceSerial
        runServer = state.server
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

    /// 선택한 계획의 계정 키와 project.yaml accounts의 id_env·password_env를 합친 목록(계획 쪽이 앞).
    func accountEnvKeys(for project: ProjectRef) -> [String] {
        var keys = selectedPlan?.accountEnvKeys ?? []
        let yaml = (try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? ""
        for key in Workspace.accountEnvKeys(projectYAML: yaml) where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    func environmentNames(for project: ProjectRef) -> [String] {
        let file = project.dir.appending(path: "project.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("environments:") }) else { return [] }
        // `dev:` 같은 하위 블록과 `default: dev` 같은 값 줄을 모두 읽는다. default가 가리키는 이름이 맨 앞.
        var names: [String] = []
        var defaultName: String?
        for line in lines.dropFirst(start + 1) {
            if !line.isEmpty, line.first?.isWhitespace == false { break }
            guard line.prefix(while: { $0 == " " }).count == 2 else { continue }
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if key == "default" {
                if !value.isEmpty { defaultName = value }
            } else if !names.contains(key) {
                names.append(key)
            }
        }
        if let defaultName {
            names.removeAll { $0 == defaultName }
            names.insert(defaultName, at: 0)
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

    private func runStage(_ stage: Stage, prompt: String, record: StageRecord? = nil) async -> Bool {
        guard let workspace else { return false }
        activeStage = stage
        phase = .stage(stage)
        stageLog = ""
        stageDecision = nil
        stageCost = nil
        stageFailed = false
        stageWasStopped = false
        stageResultIsError = nil
        stageResultSummary = ""
        stageRawLog = ""
        stageSecretValues = selectedProject.map { project in
            let yaml = (try? String(
                contentsOf: project.dir.appending(path: "project.yaml"),
                encoding: .utf8
            )) ?? ""
            let accountKeys = Set(Workspace.accountEnvKeys(projectYAML: yaml))
            return SecretKeys.values(envURL: project.dir.appending(path: ".env"), accountKeys: accountKeys)
        } ?? []
        stageStartedAt = .now
        stageIsRunning = true
        // 앞 단계의 출력·비용을 비운 뒤에 첫 기록을 남긴다.
        liveStageRecord = record
        saveLiveStageRecord()
        var environment = ["ARTEMIS_HOME": expandedPath(artemisHome)]
        if !artemisTracesDir.isEmpty {
            environment["ARTEMIS_TRACES_DIR"] = expandedPath(artemisTracesDir)
        }
        let runner = ClaudeRunner(
            executable: resolvedClaudeURL(),
            workspaceRoot: workspace.root,
            environment: environment
        )
        claudeRunner = runner
        do {
            for try await event in runner.run(prompt: prompt) {
                handle(event)
            }
            stageIsRunning = false
            claudeRunner = nil
            activeStage = nil
            let succeeded = !stageWasStopped && stageResultIsError == false
            stageFailed = !stageWasStopped && !succeeded
            finishLiveStageRecord(stageWasStopped ? .cancelled : succeeded ? .succeeded : .failed)
            return succeeded
        } catch {
            stageIsRunning = false
            claudeRunner = nil
            activeStage = nil
            stageFailed = !stageWasStopped
            finishLiveStageRecord(stageWasStopped ? .cancelled : .failed)
            if !stageWasStopped && !Task.isCancelled {
                notice = AppNotice(title: "Claude Code 실행 실패", message: redactStageText(error.localizedDescription))
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
        activeRun != nil || activeStage != nil
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
        pollFailureReasons = [:]
        traceLogMissingScenarioIDs = []
        adbUnavailableScenarioIDs = []
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
        server: String,
        reset: ResetContext? = nil,
        prepare: PrepareResult? = nil
    ) -> RunOrchestrator {
        RunOrchestrator(
            api: ArtemisClient(base: URL(string: artemisURL) ?? URL(string: "http://127.0.0.1:8100")!),
            shell: ProcessShellRunner(),
            runDir: runDir,
            plan: plan,
            scenarios: scenarios,
            deviceSerial: deviceSerial,
            server: server,
            planRelativePath: workspace.map { relativePath(plan.url, from: $0.root) } ?? plan.url.path,
            artemisHome: URL(fileURLWithPath: expandedPath(artemisHome)),
            tracesDir: artemisTracesDir.isEmpty
                ? nil
                : URL(fileURLWithPath: expandedPath(artemisTracesDir)),
            adbPath: resolvedADBPath(),
            reset: reset,
            prepare: prepare
        )
    }

    private func consumeRun(
        _ orchestrator: RunOrchestrator,
        starting operation: @escaping @Sendable () async -> Bool,
        runDir: URL
    ) async {
        // 실행 중에는 .env를 잠그므로 시작할 때 한 번 읽은 값을 끝까지 쓴다.
        runSecretValues = activeRun.map { activeRun in
            let project = activeRun.project
            let yaml = (try? String(
                contentsOf: project.dir.appending(path: "project.yaml"),
                encoding: .utf8
            )) ?? ""
            let accountKeys = Set(Workspace.accountEnvKeys(projectYAML: yaml))
            return SecretKeys.values(envURL: project.dir.appending(path: ".env"), accountKeys: accountKeys)
        } ?? []
        let operationTask = Task { await operation() }
        runOperationTask = operationTask
        defer { runOperationTask = nil }
        for await event in orchestrator.events {
            handle(event)
            if case .finished = event { break }
        }
        let didRun = await operationTask.value
        guard !isTerminating else {
            activeRun = nil
            phase = .empty
            return
        }
        // 다시 돌리지 못했으면 판정(Claude 비용·summary 다시 쓰기)을 하지 않고 결과 화면으로 돌아간다.
        guard didRun else {
            let reason = await orchestrator.lastRetryRefusal?.reason ?? "알 수 없는 이유"
            var message = "다시 돌리지 못했어요 — \(reason)"
            activeRun = nil
            do {
                try loadResults(from: runDir)
            } catch {
                // 결과를 못 읽은 이유도 같은 알림에 붙인다(따로 띄우면 하나가 덮인다).
                showEmptyResults(for: runDir, error: error, notify: false)
                message += "\n결과를 읽지 못했어요: \(error.localizedDescription)"
            }
            notice = AppNotice(title: "다시 돌릴 수 없어요", message: message)
            return
        }
        guard let context = activeRun,
              context.runDir.standardizedFileURL == runDir.standardizedFileURL
        else { return }
        let started = Date.now
        let succeeded = await runStage(
            .judge,
            prompt: StagePrompt.judge(
                project: context.project,
                plan: workspace.map { relativePath(context.plan.url, from: $0.root) } ?? context.plan.url.path,
                runDir: workspace.map { relativePath(runDir, from: $0.root) } ?? runDir.path
            ),
            record: StageRecord(stage: .judge, key: StageRecord.judgeKey(project: context.project, planName: runDir.deletingLastPathComponent().lastPathComponent, runName: runDir.lastPathComponent), startedAt: .now, status: .running)
        )
        judgeDuration = Date.now.timeIntervalSince(started)
        if succeeded {
            do {
                try loadResults(from: context.runDir)
            } catch {
                loadErrorShownRuns.remove(context.runDir.standardizedFileURL.path)
                showEmptyResults(for: context.runDir, error: error)
            }
        } else {
            clearResults()
        }
        activeRun = nil
    }

    private func handle(_ event: RunEvent) {
        runEvents.append(event)
        switch event {
        case .state(let id, let state):
            runStates[id] = state
            switch state {
            case .preparing, .running:
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
        case .pollFailing(let id, let reason):
            pollFailureReasons[id] = reason
        case .pollRecovered(let id):
            pollFailureReasons.removeValue(forKey: id)
        case .traceLogMissing(let id):
            traceLogMissingScenarioIDs.insert(id)
        case .adbUnavailable(let id):
            adbUnavailableScenarioIDs.insert(id)
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

    /// 결과를 읽지 못해도 빈 결과 화면은 보이고, 왜 못 읽었는지는 실행 폴더마다 한 번 알린다.
    private func showEmptyResults(for runDir: URL, error: Error, notify: Bool = true) {
        clearResults()
        selectedRun = runDir
        phase = .results(runDir: runDir)
        if notify, loadErrorShownRuns.insert(runDir.standardizedFileURL.path).inserted {
            notice = AppNotice(title: "결과를 읽지 못했어요", message: error.localizedDescription)
        }
    }

    private func clearResults() {
        runResults = nil
        runTotals = nil
        review = Review()
        selectedResultID = nil
    }

    /// 판정 다시 하기에 쓸 실행 정보. 찾지 못하면 이유를 알리고 nil.
    private func runContext(for runDir: URL) -> ActiveRun? {
        guard let workspace else { return nil }
        guard let data = try? Data(contentsOf: runDir.appending(path: "run-state.json")),
              let state = try? JSONDecoder().decode(RunStateFile.self, from: data)
        else {
            notice = AppNotice(title: "판정할 수 없어요", message: "실행 폴더의 run-state.json을 읽지 못했어요.")
            return nil
        }
        guard let project = projects.first(where: {
            runDir.standardizedFileURL.path.hasPrefix($0.dir.standardizedFileURL.path + "/")
        }) else {
            notice = AppNotice(title: "판정할 수 없어요", message: "실행 폴더에 해당하는 프로젝트를 찾지 못했어요.")
            return nil
        }
        // 예전 빌드는 plan에 파일 이름만, 새 빌드는 작업 공간 기준 상대 경로를 남긴다.
        guard let planURL = workspace.resolvePlan(state.plan, projectDir: project.dir) else {
            notice = AppNotice(title: "판정할 수 없어요", message: "계획 파일을 찾지 못해 판정할 수 없어요: \(state.plan)")
            return nil
        }
        let plan: PlanDocument
        do {
            plan = try PlanDocument.load(planURL)
        } catch {
            show(error)
            return nil
        }
        return ActiveRun(
            runDir: runDir,
            project: project,
            plan: plan,
            scenarioIDs: state.order
        )
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

    private var detachedHeadNotice: AppNotice {
        AppNotice(title: "커밋할 수 없어요", message: "작업 공간이 브랜치가 아닌 커밋(분리된 HEAD)에 있어요. main 브랜치로 옮긴 뒤 다시 해 주세요.")
    }

    private func workspaceHead(_ workspace: Workspace) async throws -> GitHead {
        // 분리된 HEAD면 symbolic-ref -q가 아무것도 찍지 않고 1로 끝난다. 그 밖의 실패는 오류로 본다.
        let result = try await ProcessShellRunner().run(
            "/usr/bin/git",
            ["-C", workspace.root.path, "symbolic-ref", "--short", "-q", "HEAD"]
        )
        guard result.status == 0 || result.status == 1 else { throw shellError(result.out) }
        return GitHead(symbolicRefStatus: result.status, output: result.out)
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
        case .result(let isError, let costUSD, let summary):
            stageCost = costUSD
            stageResultIsError = isError
            stageResultSummary = summary
            appendStageOutput(summary)
        case .rateLimits(let limits):
            rateLimits = limits
        }
    }

    private func appendStageOutput(_ text: String) {
        if !stageRawLog.isEmpty { stageRawLog += "\n" }
        stageRawLog += text
        let text = redactStageText(text)
        if !stageLog.isEmpty { stageLog += "\n" }
        stageLog += text
        stageDecision = text.components(separatedBy: .newlines)
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("결정 필요:") })?
            .trimmingCharacters(in: .whitespaces)
        scheduleLiveStageRecordSave()
    }

    /// 출력이 이어지는 동안은 2초에 한 번만 저장한다. 앱이 갑자기 꺼져도 그때까지의 출력이 남는다.
    private func scheduleLiveStageRecordSave() {
        guard liveStageRecord != nil, stageRecordSaveTask == nil else { return }
        stageRecordSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.stageRecordSaveTask = nil
            self.saveLiveStageRecord()
        }
    }

    private func saveLiveStageRecord() {
        guard var record = liveStageRecord else { return }
        record.log = stageLog
        record.cost = stageCost
        liveStageRecord = record
        try? stageRecordStore.save(record)
    }

    private func finishLiveStageRecord(_ status: StageRecord.Status) {
        stageRecordSaveTask?.cancel()
        stageRecordSaveTask = nil
        liveStageRecord?.status = status
        liveStageRecord?.finishedAt = .now
        saveLiveStageRecord()
        liveStageRecord = nil
    }

    private func planURLFromStageOutput(for project: ProjectRef) throws -> URL? {
        guard let workspace else { return nil }
        for line in stageRawLog.components(separatedBy: .newlines).reversed() {
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

    /// 준비를 시작할 때 정하는 실행 폴더 경로(만들지 않는다).
    private func plannedRunDirectory(project: ProjectRef, plan: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return project.dir.appending(path: "runs")
            .appending(path: plan.deletingPathExtension().lastPathComponent)
            .appending(path: formatter.string(from: .now))
    }

    /// 정해 둔 경로가 그새 생겼으면 1분 뒤 이름으로 만든다.
    private func createRunDirectory(planned: URL, workspace: Workspace, project: ProjectRef, plan: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: planned.path) else {
            try FileManager.default.createDirectory(at: planned, withIntermediateDirectories: true)
            return planned
        }
        return try makeRunDirectory(workspace: workspace, project: project, plan: plan)
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

    /// Claude Code에서 온 글을 화면에 보이기 전에 프로젝트 .env 값을 가린다.
    private func redactStageText(_ text: String) -> String {
        SecretRedactor.redact(text, values: stageSecretValues)
    }

    private func resolvedClaudeURL() -> URL {
        let path = claudePath.isEmpty ? "~/.local/bin/claude" : claudePath
        return URL(fileURLWithPath: expandedPath(path))
    }

    /// 승인 시트가 에뮬레이터 이름을 읽을 때 쓰는 adb.
    var adbExecutable: String? { resolvedADBPath() }

    private func resolvedADBPath() -> String? {
        let candidates = adbPath.isEmpty
            ? [
                "~/Library/Android/sdk/platform-tools/adb",
                "/opt/homebrew/bin/adb",
                "/usr/local/bin/adb",
            ]
            : [adbPath]
        return candidates
            .map(expandedPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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
