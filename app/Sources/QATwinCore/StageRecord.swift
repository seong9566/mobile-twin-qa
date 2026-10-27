import Foundation

/// 등록·계획 같은 Claude Code 단계의 마지막 실행 기록. 앱을 다시 띄워도 단계 화면에서 볼 수 있게 남긴다.
/// 출력은 .env 값을 가린 것만 담는다.
public struct StageRecord: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case cancelled
        /// 실행 중으로 남아 있었는데 지금 이 앱이 돌리고 있지 않음(앱 종료·재실행으로 끊김).
        case interrupted
    }

    public var stage: Stage
    public var key: String
    /// 등록 단계를 다시 시작할 때 쓴다.
    public var sourcePath: String?
    public var category: ProjectCategory?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var cost: Double?
    public var log: String

    public init(
        stage: Stage,
        key: String,
        sourcePath: String? = nil,
        category: ProjectCategory? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: Status,
        cost: Double? = nil,
        log: String = ""
    ) {
        self.stage = stage
        self.key = key
        self.sourcePath = sourcePath
        self.category = category
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.cost = cost
        self.log = log
    }

    /// 등록은 아직 프로젝트가 없으므로 소스 폴더 이름(= 프로젝트 이름)으로, 나머지는 프로젝트 ID로 찾는다.
    public static func registerKey(projectName: String) -> String { projectName }
    public static func planKey(project: ProjectRef) -> String { project.id }
    /// 판정은 실행 폴더마다 하나. url(stage:key:)가 `/`를 `_`로 바꾼다.
    public static func judgeKey(project: ProjectRef, runName: String) -> String { "\(project.id)/\(runName)" }
}

public struct StageRecordStore: Sendable {
    public let dir: URL
    /// 기록 하나에 남기는 출력의 최대 글자 수(뒤쪽을 남긴다).
    public static let logLimit = 200_000

    public init(dir: URL) {
        self.dir = dir
    }

    /// ~/Library/Application Support/QATwin/stage-records — 작업 공간(git) 밖에 둔다.
    public static var standard: StageRecordStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StageRecordStore(dir: base.appending(path: "QATwin/stage-records", directoryHint: .isDirectory))
    }

    /// running으로 남은 기록은 isLive가 false면 interrupted로 돌려준다.
    public func load(stage: Stage, key: String, isLive: Bool) -> StageRecord? {
        guard let data = try? Data(contentsOf: url(stage: stage, key: key)),
              var record = try? Self.decoder.decode(StageRecord.self, from: data)
        else { return nil }
        if record.status == .running, !isLive {
            record.status = .interrupted
        }
        return record
    }

    /// 그 단계의 가장 최근 기록(키와 무관). 프로젝트가 아직 없는 등록 기록을 찾을 때 쓴다.
    public func latest(stage: Stage) -> StageRecord? {
        let prefix = url(stage: stage, key: "").lastPathComponent.replacingOccurrences(of: ".json", with: "")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .max { modified($0) < modified($1) }
        guard let newest, let data = try? Data(contentsOf: newest),
              var record = try? Self.decoder.decode(StageRecord.self, from: data)
        else { return nil }
        if record.status == .running { record.status = .interrupted }
        return record
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    public func save(_ record: StageRecord) throws {
        var record = record
        if record.log.count > Self.logLimit {
            record.log = String(record.log.suffix(Self.logLimit))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url(stage: record.stage, key: record.key), options: .atomic)
    }

    func url(stage: Stage, key: String) -> URL {
        let safeKey = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        let stageName = switch stage {
        case .register: "register"
        case .plan: "plan"
        case .prepare: "prepare"
        case .judge: "judge"
        }
        return dir.appending(path: "\(stageName)-\(safeKey).json")
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
