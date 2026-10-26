import Foundation
import Testing
@testable import QATwinCore

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func response(
    for request: URLRequest,
    status: Int = 200,
    body: String
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        Data(body.utf8)
    )
}

private func stubbedClient() -> (ArtemisClient, URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    return (ArtemisClient(base: URL(string: "http://artemis.test:8100")!, session: session), session)
}

private func artemisTempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(
        path: "QATwinCoreArtemisTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
}

@Suite(.serialized)
struct ArtemisTests {
    @Test func runPostsGoalOptionsSerial() async throws {
        URLProtocolStub.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/run")
            let body = try #require(bodyData(of: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json == ["goal": "g", "profile": "pro", "device_serial": "D1"])
            return response(
                for: request,
                body: #"{"status":"started","tasks":[{"session_id":"S1","goal":"g"}]}"#
            )
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }

        #expect(try await client.run(goal: "g", options: ["profile": "pro"], deviceSerial: "D1") == "S1")
    }

    @Test func run409IsDeviceLocked() async {
        URLProtocolStub.handler = { request in
            response(for: request, status: 409, body: #"{"detail":"device locked"}"#)
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }

        await #expect(throws: ArtemisError.deviceLocked) {
            try await client.run(goal: "g", options: [:], deviceSerial: "D1")
        }
    }

    @Test func connectionRefusedIsUnreachable() async {
        URLProtocolStub.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }

        await #expect(throws: ArtemisError.unreachable) {
            try await client.devices()
        }
    }

    @Test func readsDevicesStateUsageAndStops() async throws {
        URLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/devices"):
                return response(
                    for: request,
                    body: #"{"devices":[{"serial":"DEMO1","state":"device","model":"Pixel 8","is_busy":false,"active_session_id":null}]}"#
                )
            case ("GET", "/api/sessions/S1"):
                return response(
                    for: request,
                    body: #"{"session_id":"S1","status":"new-state","start_time":1.0,"end_time":null}"#
                )
            case ("GET", "/api/sessions/S1/usage"):
                return response(
                    for: request,
                    body: #"{"session_id":"S1","llm_calls":26,"prompt_tokens":520983,"completion_tokens":12633,"total_tokens":533616}"#
                )
            case ("POST", "/api/stop"):
                let body = try #require(bodyData(of: request))
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(json == ["session_id": "S1"])
                return response(for: request, body: #"{"status":"stopped"}"#)
            default:
                return response(for: request, status: 404, body: "{}")
            }
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }

        let devices = try await client.devices()
        #expect(devices == [ArtemisDevice(serial: "DEMO1", state: "device", model: "Pixel 8", is_busy: false)])
        #expect(try await client.state("S1") == .unknown)
        #expect(
            try await client.usage("S1")
                == Usage(llm_calls: 26, prompt_tokens: 520983, completion_tokens: 12633)
        )
        try await client.stop("S1")
    }

    @Test func saveArtifactsWritesFilesAndVideo() async throws {
        let checks = #"{"records":[{"kind":"assert","passed":true}]}"#
        let usage = #"{"session_id":"S1","llm_calls":26,"prompt_tokens":520983,"completion_tokens":12633,"total_tokens":533616}"#
        let video = #"{"session_id":"S1","status":"ready","has_video":true,"video_url":"/videos/traces/x/recording.mp4?v=1"}"#
        let recording = Data([0, 1, 2, 3])
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/sessions/S1/checks":
                return response(for: request, body: checks)
            case "/api/sessions/S1/usage":
                return response(for: request, body: usage)
            case "/api/sessions/S1/video":
                return response(for: request, body: video)
            case "/videos/traces/x/recording.mp4":
                #expect(request.url?.query == "v=1")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    recording
                )
            default:
                return response(for: request, status: 404, body: "{}")
            }
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }
        let directory = artemisTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await client.saveArtifacts("S1", to: directory))
        #expect(try Data(contentsOf: directory.appending(path: "checks.json")) == Data(checks.utf8))
        #expect(try Data(contentsOf: directory.appending(path: "usage.json")) == Data(usage.utf8))
        #expect(try Data(contentsOf: directory.appending(path: "video.json")) == Data(video.utf8))
        #expect(try Data(contentsOf: directory.appending(path: "video.mp4")) == recording)
    }

    @Test func saveArtifactsWithoutVideoURLReturnsFalse() async throws {
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/sessions/S1/checks":
                return response(for: request, body: #"{"records":[]}"#)
            case "/api/sessions/S1/usage":
                return response(
                    for: request,
                    body: #"{"session_id":"S1","llm_calls":0,"prompt_tokens":0,"completion_tokens":0}"#
                )
            case "/api/sessions/S1/video":
                return response(
                    for: request,
                    body: #"{"session_id":"S1","status":"ready","has_video":false,"video_url":""}"#
                )
            default:
                return response(for: request, status: 404, body: "{}")
            }
        }
        let (client, session) = stubbedClient()
        defer { session.invalidateAndCancel() }
        let directory = artemisTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await !client.saveArtifacts("S1", to: directory))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "video.mp4").path))
    }

    @Test func stallDetector() {
        let now = Date()
        #expect(
            StallDetector.evaluate(log: "x", modifiedAt: now.addingTimeInterval(-301), now: now)
                == .logFrozen(seconds: 301)
        )
        let idle = "Generated summary for Step 3\n"
            + String(repeating: "LLM stopped without calling any tool\n", count: 12)
        #expect(StallDetector.evaluate(log: idle, modifiedAt: now, now: now) == .idleLoop(count: 12))
        #expect(
            StallDetector.evaluate(
                log: idle + "Generated summary for Step 4\n",
                modifiedAt: now,
                now: now
            ) == nil
        )
        #expect(StallDetector.evaluate(log: nil, modifiedAt: nil, now: now) == nil)
    }

    @Test func traceLogPath() {
        let home = URL(fileURLWithPath: "/tmp/artemis-home")
        let traces = URL(fileURLWithPath: "/tmp/custom-traces")
        #expect(
            StallDetector.traceLog(sessionID: "S1", artemisHome: home, tracesDir: nil).path
                == "/tmp/artemis-home/traces/S1/stdout.log"
        )
        #expect(
            StallDetector.traceLog(sessionID: "S1", artemisHome: home, tracesDir: traces).path
                == "/tmp/custom-traces/S1/stdout.log"
        )
    }
}

// URLProtocol로 가로챈 요청은 httpBody가 비고 httpBodyStream으로 온다.
private func bodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
