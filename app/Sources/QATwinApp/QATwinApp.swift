import AppKit
import SwiftUI

@main
struct QATwinApp: App {
    @NSApplicationDelegateAdaptor(QATwinApplicationDelegate.self) private var appDelegate
    @State private var appModel = AppModel()
    @State private var didPromptWorkspace = false
    @State private var isStopConfirmationPresented = false

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(appModel: appModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            } detail: {
                detailView
            }
            .frame(minWidth: 1040, minHeight: 680)
            .navigationTitle("QA Twin")
            .toolbar(removing: .title)
            .toolbar { toolbarContent }
            .sheet(isPresented: $appModel.isApprovalPresented) {
                ApprovalSheet(appModel: appModel)
            }
            .sheet(isPresented: $appModel.isFixRequestPresented) {
                FixRequestView(appModel: appModel)
            }
            .confirmationDialog(
                "프로젝트 분류를 선택해 주세요",
                isPresented: $appModel.isCategoryConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("회사") { Task { await appModel.registerPendingSource(as: .company) } }
                Button("개인") { Task { await appModel.registerPendingSource(as: .personal) } }
                Button("취소", role: .cancel) { appModel.pendingSourceURL = nil }
            } message: {
                Text("등록되지 않은 앱 소스 폴더예요.")
            }
            .alert(item: $appModel.notice) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("확인")))
            }
            .confirmationDialog(
                "전체 실행을 중지할까요?",
                isPresented: $isStopConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("전체 중지", role: .destructive) {
                    Task { await appModel.stopAll() }
                }
                Button("계속 실행", role: .cancel) {}
            } message: {
                Text("진행 중인 Artemis 세션을 멈추고 남은 시나리오는 미실행으로 남겨요.")
            }
            .onAppear {
                appDelegate.appModel = appModel
                chooseInitialWorkspaceIfNeeded()
                openFromLaunchArguments()
            }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView(appModel: appModel)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appModel.phase {
        case .empty:
            ContentUnavailableView {
                Label("테스트 계획을 선택해 주세요", systemImage: "checklist")
            } description: {
                Text("사이드바에서 계획을 열거나 앱 소스 폴더를 등록하세요.")
            } actions: {
                if appModel.selectedProject != nil {
                    Button("새 테스트 계획") { Task { await appModel.generatePlan() } }
                }
            }
        case .stage(let stage):
            StageRunView(appModel: appModel, stage: stage)
        case .reviewing:
            PlanListView(appModel: appModel)
        case .running(let runDir):
            RunProgressView(appModel: appModel, runDir: runDir)
        case .results(let runDir):
            ResultsView(appModel: appModel, runDir: runDir)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 1) {
                Text(toolbarTitle).font(.system(size: 13, weight: .semibold))
                Text(toolbarSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaSecondaryText)
            }
            .frame(minWidth: 140, maxWidth: 320, alignment: .leading)
        }

        ToolbarItem(placement: .principal) {
            PipelinePath(current: pipelineStep)
                .fixedSize()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if case .stage = appModel.phase {
                Button("중지", systemImage: "stop") { appModel.cancelStage() }
                    .buttonStyle(.glass)
                    .foregroundStyle(Color.qaFail)
                    .disabled(!appModel.stageIsRunning)
            }
            if appModel.phase == .reviewing {
                Button("저장") { appModel.savePlan() }
                    .buttonStyle(.glass)
                    .disabled(appModel.editedScenarioIDs.isEmpty)
                Button("실행 준비…") { appModel.isApprovalPresented = true }
                    .buttonStyle(.glassProminent)
                    .disabled(appModel.includedScenarioIDs.isEmpty)
            }
            if case .running = appModel.phase {
                Button("전체 중지…", systemImage: "stop") {
                    isStopConfirmationPresented = true
                }
                .buttonStyle(.glass)
                .foregroundStyle(Color.qaFail)
            }
            if case .results = appModel.phase {
                Button("수정 요청 md 만들기 (\(appModel.includedResultCount))") {
                    appModel.isFixRequestPresented = true
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var toolbarTitle: String {
        switch appModel.phase {
        case .stage(.plan):
            return (appModel.selectedProject?.name ?? "프로젝트") + " · 새 테스트 계획"
        case .stage(.register):
            return "새 프로젝트 등록"
        case .stage(.prepare):
            return "실행 준비"
        case .stage(.judge):
            return "결과 판정"
        case .running(let runDir):
            return "실행 \(runTitle(runDir))"
        case .results(let runDir):
            return "실행 \(runTitle(runDir)) · 결과"
        default:
            return appModel.selectedPlan?.url.lastPathComponent ?? appModel.selectedProject?.name ?? "QA Twin"
        }
    }

    private var toolbarSubtitle: String {
        if case .running = appModel.phase {
            return "\(appModel.runDeviceSerial) · \(appModel.runServer) 서버"
        }
        if case .results = appModel.phase, let results = appModel.runResults {
            return [
                results.branch,
                results.commit,
                results.appVersion.map { "앱 버전 \($0)" },
                results.device,
                results.server.map { "\($0) 서버" },
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        }
        guard let plan = appModel.selectedPlan else {
            return appModel.selectedProject?.sourcePath ?? "모바일 앱 테스트 작업 공간"
        }
        let header = plan.header
        return "\(header.branch) · \(header.commit) · 앱 버전 \(header.appVersion)"
    }

    private var pipelineStep: PipelineStep? {
        switch appModel.phase {
        case .stage(.register): .register
        case .stage(.plan): .plan
        case .stage(.prepare), .stage(.judge), .running: .run
        case .results: .results
        case .reviewing: .review
        case .empty: nil
        }
    }

    /// 개발·화면 확인용: `-openPlan <계획 경로>` 또는 `-openRun <실행 폴더 경로>`로 연다.
    private func openFromLaunchArguments() {
        let defaults = UserDefaults.standard
        if let runPath = defaults.string(forKey: "openRun") {
            appModel.openRun(at: URL(fileURLWithPath: runPath).standardizedFileURL)
            return
        }
        guard let path = defaults.string(forKey: "openPlan") else { return }
        let planURL = URL(fileURLWithPath: path).standardizedFileURL
        if let project = appModel.projects.first(where: { planURL.path.hasPrefix($0.dir.standardizedFileURL.path + "/") }) {
            appModel.selectProject(project)
        }
        do {
            try appModel.selectPlan(at: planURL)
        } catch {
            return
        }
        if defaults.string(forKey: "openSheet") == "approval" {
            appModel.isApprovalPresented = true
        }
    }

    private func runTitle(_ runDir: URL) -> String {
        let value = runDir.lastPathComponent
        guard value.count >= 15 else { return value }
        return "\(value.prefix(10)) \(value.suffix(4).prefix(2)):\(value.suffix(2))"
    }

    private func chooseInitialWorkspaceIfNeeded() {
        guard !didPromptWorkspace, appModel.workspace == nil, appModel.workspaceRoot.isEmpty else { return }
        didPromptWorkspace = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "mobile-twin-qa 루트 폴더를 선택해 주세요."
        panel.prompt = "선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.chooseWorkspaceFolder(url)
    }
}

@MainActor
final class QATwinApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else { return .terminateNow }
        let isRunning: Bool
        if case .running = appModel.phase {
            isRunning = true
        } else {
            isRunning = appModel.stageIsRunning
        }
        guard isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "실행을 중지하고 종료할까요?"
        alert.informativeText = "진행 중인 Artemis 세션과 Claude Code를 중지한 뒤 종료해요."
        alert.addButton(withTitle: "중지하고 종료")
        alert.addButton(withTitle: "계속 실행")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await appModel.stopAllForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
