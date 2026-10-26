import Foundation

public enum ProjectCategory: String, Codable, Hashable, Sendable {
    case company
    case personal
}

public struct ProjectRef: Hashable, Identifiable, Sendable {
    public let category: ProjectCategory
    public let name: String
    public let dir: URL
    public let sourcePath: String?

    public var id: String {
        "\(category.rawValue)/\(name)"
    }
}

public struct Workspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func locate(from: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = from.standardizedFileURL
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }

        while true {
            let hasAgents = fileManager.fileExists(atPath: candidate.appending(path: "AGENTS.md").path)
            let hasWorkspaceDirectory = ["templates", "personal", "company"].contains { name in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(
                    atPath: candidate.appending(path: name).path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }

            if hasAgents && hasWorkspaceDirectory {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    public func projects() throws -> [ProjectRef] {
        var projects: [ProjectRef] = []

        for category in [ProjectCategory.company, .personal] {
            let categoryDirectory = root.appending(path: category.rawValue)
            guard FileManager.default.fileExists(atPath: categoryDirectory.path) else {
                continue
            }

            let projectDirectories = try FileManager.default.contentsOfDirectory(
                at: categoryDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for directory in projectDirectories {
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      FileManager.default.fileExists(atPath: directory.appending(path: "project.yaml").path)
                else {
                    continue
                }

                projects.append(
                    ProjectRef(
                        category: category,
                        name: directory.lastPathComponent,
                        dir: directory,
                        sourcePath: try sourcePath(in: directory)
                    )
                )
            }
        }

        return projects.sorted { $0.id < $1.id }
    }

    public func project(matchingSource source: URL) throws -> ProjectRef? {
        let targetPath = normalizedPath(source.path)
        return try projects().first { project in
            guard let sourcePath = project.sourcePath else {
                return false
            }
            return normalizedPath(sourcePath) == targetPath
        }
    }

    public func plans(of project: ProjectRef) throws -> [URL] {
        try files(
            in: project.dir.appending(path: "plans"),
            where: { $0.pathExtension == "md" }
        )
    }

    public func runs(of project: ProjectRef, plan: URL) throws -> [URL] {
        let runDirectory = project.dir
            .appending(path: "runs")
            .appending(path: plan.deletingPathExtension().lastPathComponent)
        return try files(in: runDirectory) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// run-state.json의 plan 값을 계획 파일 URL로 바꾼다. 새 빌드는 작업 공간 기준 상대 경로를,
    /// 예전 빌드는 파일 이름만 남겼다. 파일 이름만 있으면 `<project>/plans/<이름>`에서 찾는다.
    /// 그 프로젝트의 `plans/` 안이 아니거나 파일이 없으면 nil.
    public func resolvePlan(_ plan: String, projectDir: URL) -> URL? {
        let candidate: URL
        if plan.hasPrefix("/") {
            candidate = URL(fileURLWithPath: plan)
        } else if plan.contains("/") {
            candidate = root.appending(path: plan)
        } else {
            candidate = projectDir.appending(path: "plans").appending(path: plan)
        }
        let plansPath = projectDir.appending(path: "plans").standardizedFileURL.path + "/"
        let standardized = candidate.standardizedFileURL
        guard standardized.path.hasPrefix(plansPath),
              FileManager.default.fileExists(atPath: standardized.path)
        else { return nil }
        return standardized
    }

    /// project.yaml `accounts:` 아래의 id_env·password_env 값(.env 키 이름)을 나온 순서대로 돌려준다.
    public static func accountEnvKeys(projectYAML text: String) -> [String] {
        var keys: [String] = []
        for line in accountsBlock(projectYAML: text) {
            for match in stripComment(line).matches(of: accountKeyPattern) where !keys.contains(String(match.2)) {
                keys.append(String(match.2))
            }
        }
        return keys
    }

    /// project.yaml `accounts:`의 역할 키 → id_env·password_env. 한 줄 `{ id_env: X, password_env: Y }`와
    /// 들여쓴 블록 형식을 읽고, 둘 중 하나라도 없는 역할은 뺀다.
    public static func accountRoles(projectYAML text: String) -> [String: AccountRole] {
        var found: [String: (id: String?, password: String?)] = [:]
        var current: (role: String, indent: Int)?
        let rolePattern = /^(\s+)([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$/

        func record(_ role: String, _ content: Substring) {
            for match in content.matches(of: accountKeyPattern) {
                if match.1 == "id_env" { found[role, default: (nil, nil)].id = String(match.2) }
                else { found[role, default: (nil, nil)].password = String(match.2) }
            }
        }

        for line in accountsBlock(projectYAML: text).dropFirst() {
            let content = stripComment(line)
            guard !content.allSatisfy(\.isWhitespace) else { continue }
            let indent = content.prefix(while: \.isWhitespace).count
            if let current, indent > current.indent {
                record(current.role, content)
            } else if let match = content.wholeMatch(of: rolePattern) {
                let role = String(match.2)
                current = (role, match.1.count)
                found[role] = found[role] ?? (nil, nil)
                record(role, match.3)
            } else {
                current = nil
            }
        }

        return found.compactMapValues { value in
            guard let id = value.id, let password = value.password else { return nil }
            return AccountRole(idEnv: id, passwordEnv: password)
        }
    }

    private nonisolated(unsafe) static let accountKeyPattern =
        /\b(id_env|password_env)\s*:\s*["']?([A-Za-z_][A-Za-z0-9_]*)/

    /// `accounts:` 줄의 나머지와 그 아래 들여쓴 줄. 칸 맨 앞 주석은 건너뛰고 블록을 끝내지 않는다.
    private static func accountsBlock(projectYAML text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("accounts:") }) else { return [] }
        var block = [String(lines[start].dropFirst("accounts:".count))]
        for line in lines.dropFirst(start + 1) {
            if line.hasPrefix("#") { continue }
            if !line.isEmpty, line.first?.isWhitespace == false { break }
            block.append(line)
        }
        return block
    }

    private static func stripComment(_ line: String) -> Substring {
        line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    }

    /// 실행 폴더가 완전히 비어 있을 때만 지운다. rmdir(2)라 확인과 삭제가 한 번에 일어나고,
    /// 비어 있지 않거나(ENOTEMPTY) 폴더가 아니면(ENOTDIR, 심볼릭 링크 포함) 실패한다.
    /// 지웠으면 그 위 `runs/<plan>/` 폴더도 비었을 때만 지운다(실패는 무시). 실행 폴더를 지웠으면 true.
    @discardableResult
    public static func removeRunDirectoryIfEmpty(_ url: URL) -> Bool {
        guard Darwin.rmdir(url.path) == 0 else { return false }
        _ = Darwin.rmdir(url.deletingLastPathComponent().path)
        return true
    }

    private func sourcePath(in projectDirectory: URL) throws -> String? {
        let localFile = projectDirectory.appending(path: "project.local.yaml")
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            return nil
        }

        let contents = try String(contentsOf: localFile, encoding: .utf8)
        guard let line = contents.split(whereSeparator: { $0.isNewline }).first(where: {
            String($0).trimmingCharacters(in: .whitespaces).hasPrefix("source_path:")
        }) else {
            return nil
        }

        let value = String(line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[1])
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func normalizedPath(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    private func files(in directory: URL, where predicate: (URL) -> Bool = { _ in true }) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter(predicate)
        .sorted {
            $0.deletingPathExtension().lastPathComponent
                > $1.deletingPathExtension().lastPathComponent
        }
    }
}

/// project.yaml `accounts`의 한 역할이 쓰는 `.env` 키 이름.
public struct AccountRole: Equatable, Sendable {
    public let idEnv: String
    public let passwordEnv: String

    public init(idEnv: String, passwordEnv: String) {
        self.idEnv = idEnv
        self.passwordEnv = passwordEnv
    }
}
