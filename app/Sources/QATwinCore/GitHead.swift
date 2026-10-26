import Foundation

/// `git rev-parse --abbrev-ref HEAD` 결과. 분리된 HEAD면 git이 `HEAD`를 돌려준다.
public enum GitHead: Equatable, Sendable {
    case detached
    case branch(String)

    public init(revParseOutput: String) {
        let name = revParseOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        self = name == "HEAD" || name.isEmpty ? .detached : .branch(name)
    }

    public var isMain: Bool {
        self == .branch("main")
    }
}
