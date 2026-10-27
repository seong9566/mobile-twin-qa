import QATwinCore
import SwiftUI

struct ApprovalSheet: View {
    @Bindable var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [ArtemisDevice] = []
    @State private var busyDeviceCount = 0
    @State private var unavailableDeviceCount = 0
    @State private var deviceSerial = ""
    @State private var server = ""
    @State private var buildInstall = true
    @State private var screenshotApproved = false
    @State private var presentKeys: Set<String> = []
    @State private var accountRoles: [String: AccountRole] = [:]
    @State private var deviceError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("이대로 실행할까요?")
                    .font(.system(size: 16, weight: .semibold))
                Text("시작하면 앱이 아래 기기에서 시나리오 \(selectedScenarios.count)개를 차례로 돌려요.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.qaSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    runOptions

                    if let project = appModel.selectedProject, let plan = appModel.selectedPlan {
                        AccountsSection(
                            keys: requiredKeys,
                            envURL: project.dir.appending(path: ".env"),
                            onPresentKeysChange: { presentKeys = $0 }
                        )
                        if !plan.accountEnvKeys.isEmpty,
                           plan.usesAllAccountKeys(for: selectedScenarios, roles: accountRoles) {
                            Text("계획에 역할 키가 없는 시나리오가 있어 계정 키를 모두 확인해요")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.qaTertiaryText)
                        }
                    }

                    if appModel.selectedProject?.category == .company {
                        Toggle(isOn: $screenshotApproved) {
                            Text("실행 중 화면 스크린샷이 LLM 제공자로 전송되는 것에 동의해요. ")
                                + Text("회사 프로젝트라 필요해요.").foregroundStyle(Color.qaTertiaryText)
                        }
                        .toggleStyle(.checkbox)
                    }

                    ForEach(dependencyWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.qaWarn)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }

            Divider()
            HStack(spacing: 8) {
                ClaudeRateLimitView(limits: appModel.rateLimits)
                    .frame(maxWidth: 320, alignment: .leading)
                Spacer()
                if let blocker {
                    Text(blocker)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.qaHold)
                }
                Button("취소") { dismiss() }
                Button("시작") {
                    let approval = Approval(
                        buildInstall: buildInstall,
                        deviceSerial: deviceSerial,
                        server: server,
                        scenarioIDs: selectedScenarios.map(\.id),
                        screenshotApproved: screenshotApproved
                    )
                    Task { await appModel.startRun(approval) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 700)
        .task { await loadDevices() }
        .onAppear {
            server = servers.first ?? ""
            presentKeys = currentPresentKeys
            accountRoles = currentAccountRoles
        }
    }

    private var runOptions: some View {
        VStack(spacing: 0) {
            optionRow("기기", alignment: hasExcludedDevices ? .top : .center) {
                VStack(alignment: .leading, spacing: 4) {
                    if devices.isEmpty {
                        Text(deviceError ?? "기기 없음 — USB 연결과 잠금 해제를 확인하세요")
                            .foregroundStyle(Color.qaTertiaryText)
                        Button("다시 확인") { Task { await loadDevices() } }
                            .controlSize(.small)
                    } else {
                        Picker("기기", selection: $deviceSerial) {
                            ForEach(devices, id: \.serial) { device in
                                Text(deviceLabel(device)).tag(device.serial)
                            }
                        }
                        .labelsHidden()
                    }
                    if busyDeviceCount > 0 {
                        Text("사용 중인 기기 \(busyDeviceCount)대는 뺐어요")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.qaTertiaryText)
                    }
                    if unavailableDeviceCount > 0 {
                        Text("연결은 됐지만 쓸 수 없는 기기 \(unavailableDeviceCount)대 — USB 디버깅 허용을 확인하세요")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.qaWarn)
                    }
                }
            }
            Divider()
            optionRow("서버") {
                Picker("서버", selection: $server) {
                    ForEach(servers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .disabled(servers.isEmpty)
            }
            Divider()
            optionRow("빌드·설치") {
                Toggle("", isOn: $buildInstall)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            optionRow("시나리오", alignment: .top) {
                Text(selectedScenarios.map(\.id).joined(separator: " → "))
            }

            let humanTasks = selectedScenarios.filter { $0.grade == .B }
            if !humanTasks.isEmpty {
                Divider()
                optionRow("사람이 할 일", alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(humanTasks) { scenario in
                            Label {
                                Text("\(scenario.id) \(scenario.gradeNote ?? "사람의 확인이 필요해요")")
                            } icon: {
                                Image(systemName: "bell")
                            }
                        }
                    }
                    .foregroundStyle(Color.qaHold)
                }
            }
        }
        .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
    }

    private func optionRow<Content: View>(
        _ label: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.qaSecondaryText)
                .frame(width: 92, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }

    private var selectedScenarios: [Scenario] {
        appModel.automaticScenarios.filter { appModel.includedScenarioIDs.contains($0.id) }
    }

    private var servers: [String] {
        guard let project = appModel.selectedProject else { return [] }
        return appModel.environmentNames(for: project)
    }

    private var dependencyWarnings: [String] {
        let positions = Dictionary(
            uniqueKeysWithValues: selectedScenarios.enumerated().map { ($0.element.id, $0.offset) }
        )
        return selectedScenarios.flatMap { scenario in
            scenario.dependsOn.compactMap { dependency in
                guard let dependencyIndex = positions[dependency] else {
                    return "\(scenario.id)의 사전 조건 \(dependency)가 이번 실행에 없어 보류될 거예요"
                }
                guard let scenarioIndex = positions[scenario.id], dependencyIndex > scenarioIndex else {
                    return nil
                }
                return "\(scenario.id)의 사전 조건 \(dependency)가 뒤에 있어 보류될 거예요"
            }
        }
    }

    private var currentPresentKeys: Set<String> {
        guard let project = appModel.selectedProject else { return [] }
        return EnvFile(url: project.dir.appending(path: ".env")).presentKeys()
    }

    private var currentAccountRoles: [String: AccountRole] {
        guard let project = appModel.selectedProject else { return [:] }
        let yaml = (try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? ""
        return Workspace.accountRoles(projectYAML: yaml)
    }

    /// 선택한 시나리오의 역할 키로 고른 계정 키. 역할 키가 없는 시나리오가 있으면 계획의 계정 키 전체.
    private var requiredKeys: [String] {
        appModel.selectedPlan?.requiredEnvKeys(for: selectedScenarios, roles: accountRoles) ?? []
    }

    private var blocker: String? {
        let missing = requiredKeys.filter { !presentKeys.contains($0) }
        if !missing.isEmpty { return missing.joined(separator: ", ") + " 값이 없어요" }
        if devices.isEmpty || deviceSerial.isEmpty { return "기기를 연결하고 잠금을 해제해 주세요" }
        if server.isEmpty { return "서버를 선택해 주세요" }
        if appModel.selectedProject?.category == .company, !screenshotApproved {
            return "스크린샷 전송 동의가 필요해요"
        }
        return nil
    }

    private func loadDevices() async {
        guard let base = URL(string: appModel.artemisURL) else {
            deviceError = "Artemis 주소를 확인해 주세요"
            return
        }
        do {
            let choices = ArtemisDevice.choices(from: try await ArtemisClient(base: base).devices())
            devices = choices.usable
            busyDeviceCount = choices.busyCount
            unavailableDeviceCount = choices.unavailableCount
            deviceSerial = devices.first?.serial ?? ""
            deviceError = nil
        } catch ArtemisError.unreachable {
            devices = []
            busyDeviceCount = 0
            unavailableDeviceCount = 0
            deviceError = "Artemis 서버에 연결하지 못했어요 (\(appModel.artemisURL)) — 설정의 주소를 확인하거나 서버를 띄워 주세요"
        } catch ArtemisError.http(let code) {
            devices = []
            busyDeviceCount = 0
            unavailableDeviceCount = 0
            deviceError = "기기 목록을 읽지 못했어요 — Artemis 오류 \(code)"
        } catch ArtemisError.badResponse {
            devices = []
            busyDeviceCount = 0
            unavailableDeviceCount = 0
            deviceError = "기기 목록을 읽지 못했어요 — Artemis 오류 응답"
        } catch ArtemisError.deviceLocked {
            devices = []
            busyDeviceCount = 0
            unavailableDeviceCount = 0
            deviceError = "기기 목록을 읽지 못했어요 — 폰 잠김(409)"
        } catch {
            devices = []
            busyDeviceCount = 0
            unavailableDeviceCount = 0
            deviceError = "기기 목록을 읽지 못했어요 — \(error.localizedDescription)"
        }
    }

    private var hasExcludedDevices: Bool {
        busyDeviceCount > 0 || unavailableDeviceCount > 0
    }

    private func deviceLabel(_ device: ArtemisDevice) -> String {
        [device.model, device.serial].compactMap { $0 }.joined(separator: " · ")
    }
}

