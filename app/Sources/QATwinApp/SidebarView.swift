import AppKit
import QATwinCore
import SwiftUI

struct SidebarView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Button {
                chooseSourceFolder()
            } label: {
                Label("앱 소스 폴더 열기…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    projectSection(.company, title: "회사")
                    projectSection(.personal, title: "개인")
                }
            }

            Divider()
            ClaudeRateLimitView(limits: appModel.rateLimits, compact: true)
        }
        .padding(8)
        .background(Color.qaSidebar)
        .task {
            while !Task.isCancelled {
                appModel.refreshRateLimits()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ category: ProjectCategory, title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.qaTertiaryText)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)

        ForEach(appModel.projects.filter { $0.category == category }) { project in
            Button {
                appModel.selectProject(project)
            } label: {
                Label(project.name, systemImage: "folder")
                    .fontWeight(appModel.selectedProject?.id == project.id ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        appModel.selectedProject?.id == project.id && appModel.selectedPlan == nil
                            ? Color.qaAccentWeak : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)

            if appModel.selectedProject?.id == project.id {
                let plans = appModel.plans(for: project)
                if !plans.isEmpty {
                    sidebarLabel("계획")
                }
                ForEach(plans, id: \.self) { plan in
                    planRow(plan, project: project)
                }
                if let selectedPlan = appModel.selectedPlan?.url {
                    let runs = appModel.runs(for: project, plan: selectedPlan)
                    if !runs.isEmpty {
                        sidebarLabel("실행")
                    }
                    ForEach(runs, id: \.self) { run in
                        runRow(run)
                    }
                }
            }
        }
    }

    private func sidebarLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(Color.qaTertiaryText)
            .padding(.leading, 24)
            .padding(.top, 4)
    }

    private func planRow(_ plan: URL, project: ProjectRef) -> some View {
        Button {
            do {
                try appModel.selectPlan(at: plan)
            } catch {
                appModel.notice = AppNotice(title: "계획을 열지 못했어요", message: error.localizedDescription)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc")
                Text(dateLabel(plan.lastPathComponent))
                Spacer()
                if appModel.runs(for: project, plan: plan).isEmpty {
                    Text("실행 전")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.qaTertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.leading, 16)
            .frame(height: 26)
            .background(
                isSelectedPlan(plan)
                    ? Color.qaAccent : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(isSelectedPlan(plan) ? .white : Color.qaText)
        }
        .buttonStyle(.plain)
    }

    private func runRow(_ run: URL) -> some View {
        Button {
            appModel.selectRun(run)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    Text(runLabel(run.lastPathComponent))
                    Spacer()
                }
                RunTapeView(cells: appModel.tape(for: run), mini: true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .padding(.leading, 16)
            .background(
                appModel.selectedRun == run ? Color.qaAccentWeak : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func isSelectedPlan(_ plan: URL) -> Bool {
        guard appModel.selectedRun == nil, let selected = appModel.selectedPlan?.url else { return false }
        return selected.resolvingSymlinksInPath().path == plan.resolvingSymlinksInPath().path
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "열기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appModel.chooseSourceFolder(url) }
    }

    private func dateLabel(_ filename: String) -> String {
        filename.count >= 10 ? String(filename.prefix(10)) : filename
    }

    private func runLabel(_ filename: String) -> String {
        guard filename.count >= 15 else { return filename }
        return "\(filename.dropFirst(5).prefix(5)) \(filename.suffix(4).prefix(2)):\(filename.suffix(2))"
    }
}

struct ClaudeRateLimitView: View {
    let limits: ClaudeRateLimits?
    var compact = false

    var body: some View {
        if let limits {
            VStack(alignment: .leading, spacing: 5) {
                meter(label: compact ? "5시간" : "Claude 5시간", value: limits.fiveHourPct)
                if compact {
                    meter(label: "주간", value: limits.sevenDayPct)
                    Text("Claude Code · \(time(limits.updatedAt)) 기준")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.qaTertiaryText)
                } else {
                    Text(summary(limits))
                        .font(.system(size: 11))
                        .foregroundStyle(isWarning(limits) ? Color.qaWarn : Color.qaTertiaryText)
                }
            }
        } else {
            Text("사용률 미확인")
                .font(.system(size: 11))
                .foregroundStyle(Color.qaTertiaryText)
        }
    }

    private func meter(label: String, value: Int?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
            Text(value.map { "\($0)%" } ?? "-")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 32, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.qaIdle.opacity(0.65))
                    Capsule()
                        .fill((value ?? 0) >= ClaudeRateLimits.warnPct ? Color.qaTapeHold : Color.qaDone)
                        .frame(width: proxy.size.width * CGFloat(min(max(value ?? 0, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
        }
    }

    private func summary(_ limits: ClaudeRateLimits) -> String {
        let five = limits.fiveHourPct.map { "5시간 \($0)%" } ?? "5시간 -"
        let reset = limits.fiveHourResetsAt.map { " · 리셋까지 \(remaining($0))" } ?? ""
        let seven = limits.sevenDayPct.map { " · 주간 \($0)%" } ?? " · 주간 -"
        return five + reset + seven + " (\(time(limits.updatedAt)) 기준)"
    }

    private func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func isWarning(_ limits: ClaudeRateLimits) -> Bool {
        (limits.fiveHourPct ?? 0) >= ClaudeRateLimits.warnPct
            || (limits.sevenDayPct ?? 0) >= ClaudeRateLimits.warnPct
    }
}

