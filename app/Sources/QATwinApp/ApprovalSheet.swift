import QATwinCore
import SwiftUI

struct ApprovalSheet: View {
    @Bindable var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [ArtemisDevice] = []
    @State private var deviceSerial = ""
    @State private var server = ""
    @State private var screenshotApproved = false
    @State private var presentKeys: Set<String> = []
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
                            keys: plan.accountEnvKeys,
                            envURL: project.dir.appending(path: ".env"),
                            onPresentKeysChange: { presentKeys = $0 }
                        )
                    }

                    if appModel.selectedProject?.category == .company {
                        Toggle(isOn: $screenshotApproved) {
                            Text("실행 중 화면 스크린샷이 LLM 제공자로 전송되는 것에 동의해요. ")
                                + Text("회사 프로젝트라 필요해요.").foregroundStyle(Color.qaTertiaryText)
                        }
                        .toggleStyle(.checkbox)
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
        }
    }

    private var runOptions: some View {
        VStack(spacing: 0) {
            optionRow("기기") {
                if devices.isEmpty {
                    Text(deviceError ?? "기기 없음 — USB 연결과 잠금 해제를 확인하세요")
                        .foregroundStyle(Color.qaTertiaryText)
                } else {
                    Picker("기기", selection: $deviceSerial) {
                        ForEach(devices, id: \.serial) { device in
                            Text(deviceLabel(device)).tag(device.serial)
                        }
                    }
                    .labelsHidden()
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

    private var currentPresentKeys: Set<String> {
        guard let project = appModel.selectedProject else { return [] }
        return EnvFile(url: project.dir.appending(path: ".env")).presentKeys()
    }

    private var blocker: String? {
        let missing = (appModel.selectedPlan?.accountEnvKeys ?? []).filter { !presentKeys.contains($0) }
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
            devices = try await ArtemisClient(base: base).devices()
            deviceSerial = devices.first?.serial ?? ""
            deviceError = nil
        } catch {
            devices = []
            deviceError = "기기 없음 — USB 연결과 잠금 해제를 확인하세요"
        }
    }

    private func deviceLabel(_ device: ArtemisDevice) -> String {
        [device.model, device.serial].compactMap { $0 }.joined(separator: " · ")
    }
}

