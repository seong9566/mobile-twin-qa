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
            .frame(minWidth: 1280, minHeight: 680)
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
                "이 단계를 취소할까요?",
                isPresented: $appModel.isStageCancelConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("단계 취소", role: .destructive) { appModel.cancelConfirmedStage() }
                Button("계속 진행", role: .cancel) {}
            } message: {
                Text("Claude Code를 멈춰요. 쓰다 만 파일이 남았으면 확인해 주세요.")
            }
            .confirmationDialog(
                "저장하지 않은 수정 \(appModel.editedScenarioIDs.count)개가 있어요",
                isPresented: $appModel.isUnsavedEditsConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("저장하고 이동") { appModel.saveEditsThenNavigate() }
                Button("버리고 이동", role: .destructive) { appModel.discardEditsThenNavigate() }
                Button("취소", role: .cancel) { appModel.cancelNavigation() }
            } message: {
                Text("버리면 목록 확인에서 고친 goal·통과 조건이 사라져요.")
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
        .defaultSize(width: 1440, height: 860)

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
                    Button("새 테스트 계획") { appModel.requestPlanSetup() }
                }
            }
        case .stage(let stage):
            StageRunView(appModel: appModel, stage: stage)
        case .stageRecord(let stage):
            StageRecordView(appModel: appModel, stage: stage)
        case .planSetup:
            PlanSetupView(appModel: appModel)
        case .planSummary:
            PlanSummaryView(appModel: appModel)
        case .reviewing:
            PlanListView(appModel: appModel)
        case .preparing:
            PrepareView(appModel: appModel)
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
            .padding(.horizontal, 8)
        }
        // 제목은 버튼이 아니므로 툴바 유리 배경을 씌우지 않는다(글자가 캡슐에 잘린다).
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .principal) {
            PipelinePath(
                current: pipelineStep,
                available: appModel.availableSteps(),
                completed: appModel.completedSteps(),
                onSelect: appModel.showStep
            )
            .fixedSize()
        }
        // 단계 표시가 자체 유리 캡슐을 그리므로 툴바 공유 배경은 끈다(캡슐이 겹쳐 보인다).
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .primaryAction) {
            if appModel.activeStage != nil {
                Button("취소", systemImage: "xmark") { appModel.confirmStageCancel() }
                    .buttonStyle(.glass)
                    .foregroundStyle(Color.qaFail)
            }
            if appModel.phase == .reviewing {
                ToolbarActionButton(title: "저장", systemImage: "square.and.arrow.down", prominent: false) {
                    appModel.savePlan()
                }
                .disabled(appModel.editedScenarioIDs.isEmpty)
                ToolbarActionButton(title: "실행 준비…", systemImage: "play.fill", prominent: true) {
                    appModel.presentApproval()
                }
                .disabled(
                    appModel.includedScenarioIDs.isEmpty
                        || appModel.activeRun != nil
                        || appModel.activeStage != nil
                )
            }
            if case .preparing = appModel.phase {
                Button("준비 취소…", systemImage: "xmark") {
                    isStopConfirmationPresented = true
                }
                .buttonStyle(.glass)
                .foregroundStyle(Color.qaFail)
            } else if appModel.activeRun != nil, appModel.activeStage == nil {
                Button("전체 중지…", systemImage: "stop") {
                    isStopConfirmationPresented = true
                }
                .buttonStyle(.glass)
                .foregroundStyle(Color.qaFail)
            }
            if case .results = appModel.phase, appModel.runResults != nil {
                ToolbarActionButton(
                    title: "수정 요청 md 만들기 (\(appModel.includedResultCount))",
                    systemImage: "doc.text",
                    prominent: true
                ) {
                    appModel.isFixRequestPresented = true
                }
            }
        }
    }

    private var toolbarTitle: String {
        switch appModel.phase {
        case .stage(.plan), .planSetup, .planSummary:
            return (appModel.selectedProject?.name ?? "프로젝트") + " · 새 테스트 계획"
        case .stage(.register):
            return "새 프로젝트 등록"
        case .stage(.judge):
            return "결과 판정"
        case .stageRecord(let stage):
            return (appModel.selectedProject?.name ?? appModel.viewedStageRecord?.key ?? "프로젝트") + (stage == .register ? " · 등록 기록" : " · 계획 기록")
        case .preparing(let runName):
            return "실행 \(runTitle(URL(fileURLWithPath: runName))) · 준비"
        case .running(let runDir):
            return "실행 \(runTitle(runDir))"
        case .results(let runDir):
            return "실행 \(runTitle(runDir)) · 결과"
        default:
            return appModel.selectedPlan?.url.lastPathComponent ?? appModel.selectedProject?.name ?? "QA Twin"
        }
    }

    private var toolbarSubtitle: String {
        if case .preparing = appModel.phase {
            return "\(appModel.runDeviceSerial) · \(appModel.runServer) 서버"
        }
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
        case .stage(.register), .stageRecord(.register): .register
        case .stage(.plan), .stageRecord(.plan), .planSetup, .planSummary: .plan
        case .stageRecord: nil
        case .stage(.judge), .running, .preparing: .run
        case .results: .results
        case .reviewing: .review
        case .empty: nil
        }
    }

    /// 개발·화면 확인용: `-openPlan <계획 경로>` 또는 `-openRun <실행 폴더 경로>`로 연다.
    private func openFromLaunchArguments() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "openPlan") != nil || defaults.string(forKey: "openRun") != nil {
            // 화면 확인용 실행이면 창을 앞으로 가져와 활성 상태로 그린다.
            NSApp.activate()
        }
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
        guard appModel.activeRun != nil || appModel.activeStage != nil else {
            // 실행 중이 아니어도 앱이 띄운 Artemis·테스트 서버는 끝내고 나간다.
            guard appModel.hasOwnedProcesses else { return .terminateNow }
            Task {
                await appModel.terminateOwnedProcesses()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
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

/// 툴바 버튼: 주 버튼은 강조색 틴트 유리, 보조 버튼은 기본 유리, 둘 다 아이콘을 붙인다.
/// `.glassProminent`만 쓰면 이 앱에서는 강조색이 입혀지지 않아 회색으로 보여 tint를 직접 준다.
struct ToolbarActionButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        let label = Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .fontWeight(prominent ? .semibold : .regular)
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(Color.qaButtonTint)
        } else {
            // 보조 버튼은 틴트 없는 유리 — 흰 글자 + 옅은 틴트보다 활성·비활성이 잘 구분된다.
            Button(action: action) { label }
                .buttonStyle(.glass)
        }
    }
}
