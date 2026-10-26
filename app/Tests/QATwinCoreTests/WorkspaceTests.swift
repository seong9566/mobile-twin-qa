import Foundation
import Testing
@testable import QATwinCore

func fixtureRoot() -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures/ws")
}

@Test func listsProjectsBothCategories() throws {
    let ws = Workspace(root: fixtureRoot())
    #expect(try ws.projects().map(\.id).sorted() == ["company/acme", "personal/demo_app"])
}

@Test func matchesSourcePathFromLocalYaml() throws {
    let project = try Workspace(root: fixtureRoot()).project(
        matchingSource: URL(fileURLWithPath: "/tmp/demo_src/")
    )
    #expect(project?.name == "demo_app")
}

@Test func plansNewestFirstAndRunsListed() throws {
    let ws = Workspace(root: fixtureRoot())
    let project = try ws.projects().first { $0.name == "demo_app" }!
    #expect(try ws.plans(of: project).map(\.lastPathComponent).first == "2026-01-02-demo_app_test_plan.md")
    #expect(
        try ws.runs(of: project, plan: ws.plans(of: project)[0]).map(\.lastPathComponent)
            == ["2026-01-03-0900", "2026-01-02-1000"]
    )
}

@Test func locateFindsRootFromNestedDir() {
    #expect(
        Workspace.locate(from: fixtureRoot().appending(path: "personal/demo_app/plans"))?.standardizedFileURL.path
            == fixtureRoot().standardizedFileURL.path
    )
}

@Test func timedPlanSortsBeforeSameDayBasePlan() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreWorkspaceTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDirectory = root.appending(path: "personal/demo", directoryHint: .isDirectory)
    let plansDirectory = projectDirectory.appending(path: "plans", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plansDirectory, withIntermediateDirectories: true)
    try "name: demo".write(
        to: projectDirectory.appending(path: "project.yaml"),
        atomically: true,
        encoding: .utf8
    )
    for name in ["2026-10-26-demo_test_plan.md", "2026-10-26-demo_test_plan-1530.md"] {
        try "plan".write(to: plansDirectory.appending(path: name), atomically: true, encoding: .utf8)
    }
    let project = try #require(Workspace(root: root).projects().first)

    #expect(
        try Workspace(root: root).plans(of: project).map(\.lastPathComponent)
            == ["2026-10-26-demo_test_plan-1530.md", "2026-10-26-demo_test_plan.md"]
    )
}
