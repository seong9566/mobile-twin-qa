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
    /// 예전 빌드는 파일 이름만 남겼다. 파일 이름만 있으면 `<project>/plans/<이름>`에서 찾는다. 없으면 nil.
    public func resolvePlan(_ plan: String, projectDir: URL) -> URL? {
        let candidate: URL
        if plan.hasPrefix("/") {
            candidate = URL(fileURLWithPath: plan)
        } else if plan.contains("/") {
            candidate = root.appending(path: plan)
        } else {
            candidate = projectDir.appending(path: "plans").appending(path: plan)
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// project.yaml `accounts:` 아래의 id_env·password_env 값(.env 키 이름)을 나온 순서대로 돌려준다.
    public static func accountEnvKeys(projectYAML text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("accounts:") }) else { return [] }
        var block = [String(lines[start].dropFirst("accounts:".count))]
        for line in lines.dropFirst(start + 1) {
            if !line.isEmpty, line.first?.isWhitespace == false { break }
            block.append(line)
        }
        var keys: [String] = []
        let pattern = /(?:id_env|password_env)\s*:\s*["']?([A-Z][A-Z0-9_]+)/
        for line in block {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            for match in content.matches(of: pattern) where !keys.contains(String(match.1)) {
                keys.append(String(match.1))
            }
        }
        return keys
    }

    /// 실행 폴더가 완전히 비어 있을 때만(숨김 파일·하위 폴더도 없을 때) 지운다. 지웠으면 true.
    @discardableResult
    public static func removeRunDirectoryIfEmpty(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty else {
            return false
        }
        return (try? fileManager.removeItem(at: url)) != nil
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
