import Foundation

/// 작업 공간의 HEAD. `git symbolic-ref --short -q HEAD` 결과로 만든다.
public enum GitHead: Equatable, Sendable {
    case detached
    case branch(String)

    /// symbolic-ref -q는 분리된 HEAD면 아무것도 찍지 않고 1로 끝난다.
    public init(symbolicRefStatus status: Int32, output: String) {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self = status != 0 || name.isEmpty ? .detached : .branch(name)
    }

    public var isMain: Bool {
        self == .branch("main")
    }
}
