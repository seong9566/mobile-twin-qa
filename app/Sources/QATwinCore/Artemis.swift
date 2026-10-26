import Foundation

public struct ArtemisDevice: Decodable, Hashable, Sendable {
    public let serial: String
    public let state: String
    public let model: String?
    public let is_busy: Bool?
}

public enum SessionState: String, Decodable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SessionState(rawValue: value) ?? .unknown
    }
}

public struct Usage: Codable, Equatable, Sendable {
    public let llm_calls: Int
    public let prompt_tokens: Int
    public let completion_tokens: Int
}

public enum ArtemisError: Error, Equatable {
    case unreachable
    case deviceLocked
    case http(Int)
    case badResponse
}

public protocol ArtemisAPI: Sendable {
    func devices() async throws -> [ArtemisDevice]
    func run(goal: String, options: [String: String], deviceSerial: String) async throws -> String
    func state(_ sid: String) async throws -> SessionState
    func usage(_ sid: String) async throws -> Usage
    func stop(_ sid: String) async throws
    func saveArtifacts(_ sid: String, to dir: URL) async throws -> Bool
}

public struct ArtemisClient: ArtemisAPI {
    private let base: URL
    private let session: URLSession

    public init(
        base: URL = URL(string: "http://127.0.0.1:8100")!,
        session: URLSession = .shared
    ) {
        self.base = base
        self.session = session
    }

    public func devices() async throws -> [ArtemisDevice] {
        let data = try await get(path: "/api/devices")
        return try decode(DeviceResponse.self, from: data).devices
    }

    public func run(
        goal: String,
        options: [String: String],
        deviceSerial: String
    ) async throws -> String {
        var body = options
        body["goal"] = goal
        body["device_serial"] = deviceSerial
        let data = try await post(path: "/api/run", body: body, deviceLockedOnConflict: true)
        guard let sessionID = try decode(RunResponse.self, from: data).tasks.first?.session_id else {
            throw ArtemisError.badResponse
        }
        return sessionID
    }

    public func state(_ sid: String) async throws -> SessionState {
        let data = try await get(path: "/api/sessions/\(sid)")
        return try decode(StateResponse.self, from: data).status
    }

    public func usage(_ sid: String) async throws -> Usage {
        let data = try await get(path: "/api/sessions/\(sid)/usage")
        return try decode(Usage.self, from: data)
    }

    public func stop(_ sid: String) async throws {
        _ = try await post(path: "/api/stop", body: ["session_id": sid])
    }

    public func saveArtifacts(_ sid: String, to dir: URL) async throws -> Bool {
        let checks = try await get(path: "/api/sessions/\(sid)/checks")
        let usage = try await get(path: "/api/sessions/\(sid)/usage")
        let video = try await get(path: "/api/sessions/\(sid)/video")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try checks.write(to: dir.appending(path: "checks.json"))
        try usage.write(to: dir.appending(path: "usage.json"))
        try video.write(to: dir.appending(path: "video.json"))

        let response = try decode(VideoResponse.self, from: video)
        guard let videoPath = response.video_url,
              !videoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let videoURL = URL(string: videoPath, relativeTo: base)?.absoluteURL else {
            return false
        }

        let videoData = try await request(URLRequest(url: videoURL))
        try videoData.write(to: dir.appending(path: "video.mp4"))
        return true
    }

    private func get(path: String) async throws -> Data {
        try await request(URLRequest(url: endpoint(path)))
    }

    private func post(
        path: String,
        body: [String: String],
        deviceLockedOnConflict: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await self.request(request, deviceLockedOnConflict: deviceLockedOnConflict)
    }

    private func request(
        _ request: URLRequest,
        deviceLockedOnConflict: Bool = false
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw ArtemisError.unreachable
        }

        guard let response = response as? HTTPURLResponse else {
            throw ArtemisError.badResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if deviceLockedOnConflict && response.statusCode == 409 {
                throw ArtemisError.deviceLocked
            }
            throw ArtemisError.http(response.statusCode)
        }
        return data
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ArtemisError.badResponse
        }
    }
}

public enum StallSignal: Equatable, Sendable {
    case logFrozen(seconds: Int)
    case idleLoop(count: Int)
}

public enum StallDetector {
    public static let frozenSeconds = 300
    public static let idleLimit = 12

    public static func evaluate(log: String?, modifiedAt: Date?, now: Date) -> StallSignal? {
        if let modifiedAt {
            let seconds = Int(now.timeIntervalSince(modifiedAt))
            if seconds > frozenSeconds {
                return .logFrozen(seconds: seconds)
            }
        }

        guard let log,
              let summary = log.range(of: "Generated summary for Step", options: .backwards) else {
            return nil
        }
        let marker = "LLM stopped without calling any tool"
        let count = log[summary.upperBound...].components(separatedBy: marker).count - 1
        return count >= idleLimit ? .idleLoop(count: count) : nil
    }

    public static func traceLog(sessionID: String, artemisHome: URL, tracesDir: URL?) -> URL {
        (tracesDir ?? artemisHome.appending(path: "traces", directoryHint: .isDirectory))
            .appending(path: sessionID, directoryHint: .isDirectory)
            .appending(path: "stdout.log")
    }
}

private struct DeviceResponse: Decodable {
    let devices: [ArtemisDevice]
}

private struct RunResponse: Decodable {
    let tasks: [RunTask]
}

private struct RunTask: Decodable {
    let session_id: String
}

private struct StateResponse: Decodable {
    let status: SessionState
}

private struct VideoResponse: Decodable {
    let video_url: String?
}
