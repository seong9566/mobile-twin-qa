import Foundation

public struct InstallEntry: Codable, Equatable, Sendable {
    public var package: String
    public var commit: String
    public var dirty: Bool
    public var envSHA256: String
    public var at: Date

    public init(package: String, commit: String, dirty: Bool, envSHA256: String, at: Date) {
        self.package = package
        self.commit = commit
        self.dirty = dirty
        self.envSHA256 = envSHA256
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case package
        case commit
        case dirty
        case envSHA256 = "env_sha256"
        case at
    }
}

public struct InstallRecords: Sendable {
    public static func load(projectDir: URL) -> [String: InstallEntry] {
        guard let data = try? Data(contentsOf: url(projectDir: projectDir)),
              let records = try? decoder.decode([String: InstallEntry].self, from: data)
        else { return [:] }
        return records
    }

    public static func save(_ entry: InstallEntry, serial: String, projectDir: URL) throws {
        var records = load(projectDir: projectDir)
        records[serial] = entry
        try encoder.encode(records).write(to: url(projectDir: projectDir), options: .atomic)
    }

    private static func url(projectDir: URL) -> URL {
        projectDir.appending(path: ".install.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum BuildSkip: Equatable, Sendable {
    case skip
    case build(reason: String)

    public static func decide(
        entry: InstallEntry?,
        headCommit: String,
        sourceDirty: Bool,
        envSHA256: String,
        packageInstalled: Bool,
        forceRebuild: Bool
    ) -> BuildSkip {
        guard let entry else {
            return .build(reason: "이 기기에 설치한 기록이 없어요")
        }
        if entry.dirty {
            return .build(reason: "설치본이 커밋하지 않은 변경으로 빌드됐어요")
        }
        if sourceDirty {
            return .build(reason: "소스에 커밋하지 않은 변경이 있어요")
        }
        if entry.commit != headCommit {
            return .build(reason: "설치본 \(entry.commit) ≠ 소스 \(headCommit)")
        }
        if entry.envSHA256 != envSHA256 {
            return .build(reason: "서버 설정이 바뀌었어요")
        }
        if !packageInstalled {
            return .build(reason: "기기에 앱이 없어요")
        }
        if forceRebuild {
            return .build(reason: "다시 빌드를 골랐어요")
        }
        return .skip
    }
}
