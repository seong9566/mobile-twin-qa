import Foundation

public enum ProjectCategory: String, Codable, Hashable {
    case company
    case personal
}

public struct ProjectRef: Hashable, Identifiable {
    public let category: ProjectCategory
    public let name: String
    public let dir: URL
    public let sourcePath: String?

    public var id: String {
        "\(category.rawValue)/\(name)"
    }
}

public struct Workspace {
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
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
