import Foundation

/// 원본 repo의 `.env`에서 키를 골라 프로젝트 `.env`로 가져온다(스펙 5.2). 값은 화면에 보이지 않는다.
public enum EnvImport {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notFound(String)
        case tracked(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path): "원본 .env가 없어요 (\(path))"
            case .tracked(let path): "원본 .env가 git에 올라가 있어 가져오지 않아요 (\(path))"
            }
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let defaultChecked: Bool
    }

    /// 원본 `.env`의 키 이름 전부. `.env.example`에 있는 키만 기본으로 체크한다(없으면 아무것도 체크하지 않음).
    public static func candidates(sourceDir: URL, envSource: String, shell: ShellRunner) async throws -> [Candidate] {
        let sourceEnv = sourceDir.appending(path: envSource)
        guard FileManager.default.fileExists(atPath: sourceEnv.path) else {
            throw Refusal.notFound(sourceEnv.path)
        }
        // 추적 파일이면 0으로 끝난다. git이 없거나 repo가 아니면 추적되지 않은 것으로 본다.
        if let result = try? await shell.run("/usr/bin/git", ["-C", sourceDir.path, "ls-files", "--error-unmatch", envSource]),
           result.status == 0 {
            throw Refusal.tracked(sourceEnv.path)
        }
        let example = sourceEnv.deletingLastPathComponent().appending(path: ".env.example")
        let exampleKeys = Set(EnvFile(url: example).entriesInOrder().map(\.key))
        return EnvFile(url: sourceEnv).entriesInOrder().map {
            Candidate(key: $0.key, defaultChecked: exampleKeys.contains($0.key))
        }
    }

    /// 고른 키만 프로젝트 `.env`에 넣는다. 다른 줄은 그대로 둔다.
    public static func apply(keys: [String], from sourceEnv: URL, to projectEnv: URL) throws {
        let values = Dictionary(
            EnvFile(url: sourceEnv).entriesInOrder().map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let target = EnvFile(url: projectEnv)
        for key in keys {
            guard let value = values[key], !value.isEmpty else { continue }
            try target.upsert(key: key, value: value)
        }
    }
}
