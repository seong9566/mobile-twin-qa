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
    @State private var forceRebuild = false
    @State private var loginRole: String?
    @State private var checks: [PrepareStep: PrepareItemState] = [:]
    @State private var isChecking = false
    @State private var avdNames: [String: String] = [:]
    @State private var buildLine: String?
    @State private var isImportPresented = false
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

                    prepareChecks

                    if let project = appModel.selectedProject, let plan = appModel.selectedPlan {
                        AccountsSection(
                            keys: envKeys,
                            envURL: project.dir.appending(path: ".env"),
                            onPresentKeysChange: { presentKeys = $0 },
                            title: "테스트 env",
                            usage: envKeyUsage
                        )
                        HStack(spacing: 10) {
                            Button("원본 .env에서 가져오기…", systemImage: "square.and.arrow.down") {
                                isImportPresented = true
                            }
                            Text("원본 repo의 .env(git 무시)에서 고른 키만 복사해요. 값은 화면에 보이지 않아요.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.qaTertiaryText)
                        }
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
                        deviceSerial: deviceSerial,
                        server: server,
                        scenarioIDs: selectedScenarios.map(\.id),
                        screenshotApproved: screenshotApproved,
                        loginRole: loginRole,
                        forceRebuild: forceRebuild
                    )
                    Task { await appModel.startRun(approval) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 746)
        .task { await refreshChecks() }
        // 기기가 잠겨 있으면 5초마다 다시 본다(스펙 5.9).
        .task(id: isDeviceWaiting) {
            while isDeviceWaiting, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await refreshPreflight()
            }
        }
        .onChange(of: deviceSerial) { _, _ in Task { await refreshPreflight() } }
        .onChange(of: server) { _, _ in Task { await refreshPreflight() } }
        .sheet(isPresented: $isImportPresented) {
            if let project = appModel.selectedProject, let source = appModel.sourceDirectory(for: project) {
                EnvImportSheet(
                    sourceDir: source,
                    envSource: appModel.projectConfig(for: project).envSource,
                    projectEnv: project.dir.appending(path: ".env"),
                    onDone: { presentKeys = currentPresentKeys }
                )
            }
        }
        .onAppear {
            server = servers.first ?? ""
            presentKeys = currentPresentKeys
            accountRoles = currentAccountRoles
            loginRole = LoginPlan.defaultRole(scenarios: selectedScenarios, roles: accountRoles)
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
            optionRow("시나리오", alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedScenarios.map(\.id).joined(separator: " → "))
                    ForEach(selectedScenarios.filter(\.resetsAppData)) { scenario in
                        Text("\(scenario.id) 앞에서 앱 데이터를 초기화해요")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.qaTertiaryText)
                    }
                }
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

    // MARK: 준비 점검 (스펙 5.9 · 목업 3b)

    private var prepareChecks: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("준비 점검")
                    .font(.system(size: 12, weight: .semibold))
                Text(isChecking ? "확인하는 중…" : "Artemis는 기기 목록에 필요해 바로 띄우고, 테스트 서버는 시작할 때 띄워요")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.qaTertiaryText)
                Spacer()
                Button("다시 확인") { Task { await refreshChecks() } }
                    .controlSize(.small)
                    .disabled(isChecking)
            }
            VStack(spacing: 0) {
                checkRow("Artemis 서버", checks[.artemis])
                Divider()
                if case .skipped = checks[.server] {} else {
                    checkRow("테스트 서버 \(server)", checks[.server])
                    Divider()
                }
                checkRow("기기", checks[.device])
                Divider()
                buildRow
                if !accountRoles.isEmpty {
                    Divider()
                    optionRow("로그인 역할") {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("로그인 역할", selection: $loginRole) {
                                ForEach(accountRoles.keys.sorted(), id: \.self) { key in
                                    Text("\(key) — \(accountRoles[key]?.idEnv ?? "")").tag(Optional(key))
                                }
                            }
                            .labelsHidden()
                            Text(loginDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.qaTertiaryText)
                        }
                    }
                }
            }
            .background(Color.qaBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.qaLine))
        }
    }

    private func checkRow(_ title: String, _ state: PrepareItemState?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkIcon(state).frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            Text(checkText(state))
                .font(.system(size: 12))
                .foregroundStyle(checkColor(state))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }

    private var buildRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: forceRebuild || buildLine != nil ? "play.circle" : "minus")
                .foregroundStyle(Color.qaAccentInk)
                .frame(width: 16)
            Text("빌드·설치")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(forceRebuild ? "다시 빌드해요" : (buildLine ?? "건너뜀 — 기기에 설치된 빌드가 지금 소스와 같아요"))
                    .font(.system(size: 12))
                if let project = appModel.selectedProject, !appModel.projectConfig(for: project).usesQAAppEnv {
                    Text("빌드가 원본 .env를 읽어요 — 고른 서버가 빌드에 반영되지 않아요")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.qaWarn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("그래도 다시 빌드", isOn: $forceRebuild)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }

    @ViewBuilder
    private func checkIcon(_ state: PrepareItemState?) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Color.qaPass)
        case .waitingForHuman: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.qaWarn)
        case .failed: Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(Color.qaFail)
        case .skipped: Image(systemName: "minus").foregroundStyle(Color.qaTertiaryText)
        case .running, .waiting, nil: ProgressView().controlSize(.mini)
        }
    }

    private func checkText(_ state: PrepareItemState?) -> String {
        switch state {
        case .done(let detail): detail.isEmpty ? "확인했어요" : detail
        case .skipped(let detail), .waitingForHuman(let detail), .failed(let detail): detail
        case .running, .waiting, nil: "확인하는 중…"
        }
    }

    private func checkColor(_ state: PrepareItemState?) -> Color {
        switch state {
        case .waitingForHuman: .qaWarn
        case .failed: .qaFail
        default: .qaText
        }
    }

    private var loginDetail: String {
        let plan = LoginPlan.make(scenarios: selectedScenarios, roles: accountRoles, chosenRole: loginRole)
        switch plan.when {
        case .none: return "로그인하는 시나리오가 없어요"
        case .duringPrepare: return "앱이 값을 넣고 '로그인'을 눌러요. 역할 키가 적힌 시나리오는 그 역할을 써요"
        case .beforeScenario(let id): return "\(id) 앞에서 로그인해요. 역할 키가 적힌 시나리오는 그 역할을 써요"
        }
    }

    private var isDeviceWaiting: Bool {
        if case .waitingForHuman = checks[.device] { return true }
        return false
    }

    private func refreshChecks() async {
        isChecking = true
        // 먼저 점검을 돌려 Artemis가 꺼져 있으면 띄운 뒤 기기 목록을 읽는다.
        checks = await appModel.preflight(serial: deviceSerial, server: server, loginRole: loginRole, scenarioIDs: selectedScenarios.map(\.id))
        let artemis = checks[.artemis]
        await loadDevices()
        if !deviceSerial.isEmpty {
            await refreshPreflight()
            // 두 번째 점검은 이미 떠 있는 Artemis를 보므로 "띄웠어요"를 남긴다.
            if case .done(let detail) = artemis, detail.contains("띄웠") { checks[.artemis] = artemis }
        }
        isChecking = false
    }

    private func refreshPreflight() async {
        guard !deviceSerial.isEmpty else { return }
        let artemis = checks[.artemis]
        var updated = await appModel.preflight(serial: deviceSerial, server: server, loginRole: loginRole, scenarioIDs: selectedScenarios.map(\.id))
        if case .done(let detail) = artemis, detail.contains("띄웠") { updated[.artemis] = artemis }
        checks = updated
        buildLine = await buildDecisionLine()
    }

    /// 설치 기록과 지금 소스 커밋으로 빌드를 건너뛸지 미리 보인다. 서버 설정 해시는 준비 단계가 다시 본다.
    private func buildDecisionLine() async -> String? {
        guard let project = appModel.selectedProject else { return nil }
        let entry = InstallRecords.load(projectDir: project.dir)[deviceSerial]
        let source = await appModel.planSourceInfo(for: project)
        guard let entry else { return "이 기기에 설치한 기록이 없어요 → 빌드해요" }
        if source?.isDirty == true { return "소스에 커밋하지 않은 변경이 있어요 → 빌드해요" }
        if let commit = source?.commit, !entry.commit.hasPrefix(commit) {
            return "설치본 \(entry.commit.prefix(8)) ≠ 소스 \(commit) → 빌드해요"
        }
        return nil
    }

    // MARK: 테스트 env 키

    /// 로그인 키(필수) + 빌드 키(.env의 나머지 + .env.example에만 있는 키).
    private var envKeys: [String] {
        var keys = requiredKeys
        for key in buildKeys where !keys.contains(key) { keys.append(key) }
        return keys
    }

    private var envKeyUsage: [String: String] {
        var usage: [String: String] = [:]
        for key in requiredKeys { usage[key] = "로그인" }
        for key in buildKeys where usage[key] == nil { usage[key] = "빌드" }
        return usage
    }

    private var buildKeys: [String] {
        guard let project = appModel.selectedProject else { return [] }
        let accountKeys = Set(Workspace.accountEnvKeys(projectYAML: (try? String(contentsOf: project.dir.appending(path: "project.yaml"), encoding: .utf8)) ?? ""))
        var keys = EnvFile(url: project.dir.appending(path: ".env")).entriesInOrder().map(\.key).filter { !accountKeys.contains($0) }
        if let source = appModel.sourceDirectory(for: project) {
            let example = source.appending(path: appModel.projectConfig(for: project).envSource)
                .deletingLastPathComponent().appending(path: ".env.example")
            for key in EnvFile(url: example).entriesInOrder().map(\.key) where !keys.contains(key) && !accountKeys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private var blocker: String? {
        let missing = requiredKeys.filter { !presentKeys.contains($0) }
        if !missing.isEmpty { return missing.joined(separator: ", ") + " 값이 없어요" }
        if case .failed(let reason) = checks[.artemis] { return reason }
        if devices.isEmpty || deviceSerial.isEmpty { return "기기를 연결하고 잠금을 해제해 주세요" }
        if case .waitingForHuman(let reason) = checks[.device] { return reason }
        if case .waitingForHuman(let reason) = checks[.server], reason.contains("직접") { return reason }
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
        devices = []
        busyDeviceCount = 0
        unavailableDeviceCount = 0
        do {
            let choices = ArtemisDevice.choices(from: try await ArtemisClient(base: base).devices())
            devices = choices.usable
            busyDeviceCount = choices.busyCount
            unavailableDeviceCount = choices.unavailableCount
            if !devices.contains(where: { $0.serial == deviceSerial }) {
                deviceSerial = devices.first?.serial ?? ""
            }
            deviceError = nil
            for device in devices where DeviceProbe.isEmulator(device.serial) {
                if let adb = appModel.adbExecutable {
                    avdNames[device.serial] = await DeviceProbe(shell: ProcessShellRunner(), adbPath: adb).avdName(serial: device.serial)
                }
            }
        } catch ArtemisError.unreachable {
            deviceError = "Artemis 서버에 연결하지 못했어요 (\(appModel.artemisURL)) — 설정의 주소를 확인하거나 서버를 띄워 주세요"
        } catch ArtemisError.http(let code) {
            deviceError = "기기 목록을 읽지 못했어요 — Artemis 오류 \(code)"
        } catch ArtemisError.badResponse {
            deviceError = "기기 목록을 읽지 못했어요 — Artemis 오류 응답"
        } catch {
            deviceError = "기기 목록을 읽지 못했어요 — \(error.localizedDescription)"
        }
    }

    private var hasExcludedDevices: Bool {
        busyDeviceCount > 0 || unavailableDeviceCount > 0
    }

    private func deviceLabel(_ device: ArtemisDevice) -> String {
        if DeviceProbe.isEmulator(device.serial) {
            return "에뮬레이터 \(avdNames[device.serial] ?? device.model ?? "") · \(device.serial)"
        }
        return [device.model, device.serial].compactMap { $0 }.joined(separator: " · ")
    }
}

