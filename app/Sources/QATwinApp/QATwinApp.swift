import AppKit
import SwiftUI

@main
struct QATwinApp: App {
    @State private var appModel = AppModel()
    @State private var didPromptWorkspace = false

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(appModel: appModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            } detail: {
                detailView
            }
            .frame(minWidth: 1040, minHeight: 680)
            // 확정 목업은 밝은 모양이다. 어두운 모양 토큰을 만들기 전까지 밝게 고정한다.
            .preferredColorScheme(.light)
            .navigationTitle("QA Twin")
            .toolbar(removing: .title)
            .toolbar { toolbarContent }
            .sheet(isPresented: $appModel.isApprovalPresented) {
                ApprovalSheet(appModel: appModel)
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
            .onAppear {
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
        case .running:
            ContentUnavailableView("준비 완료", systemImage: "checkmark.circle", description: Text("실행 진행 화면은 다음 단계에서 연결해요."))
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
            .frame(minWidth: 260, alignment: .leading)
        }

        ToolbarItem(placement: .principal) {
            PipelinePath(current: pipelineStep)
                .fixedSize()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if case .stage = appModel.phase {
                Button("중지", systemImage: "stop") { appModel.cancelStage() }
                    .foregroundStyle(Color.qaFail)
                    .disabled(!appModel.stageIsRunning)
            }
            if appModel.phase == .reviewing {
                Button("저장") { appModel.savePlan() }
                    .disabled(appModel.editedScenarioIDs.isEmpty)
                Button("실행 준비…") { appModel.isApprovalPresented = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.includedScenarioIDs.isEmpty)
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
        default:
            return appModel.selectedPlan?.url.lastPathComponent ?? appModel.selectedProject?.name ?? "QA Twin"
        }
    }

    private var toolbarSubtitle: String {
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
        case .reviewing: .review
        case .empty: nil
        }
    }

    /// 개발·화면 확인용: `-openPlan <계획 경로>`로 실행하면 그 계획을 연다. `-openSheet approval`이면 승인 창도 연다.
    private func openFromLaunchArguments() {
        let defaults = UserDefaults.standard
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
