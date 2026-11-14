import Foundation
import XCTest
@testable import PerchCore

final class DshConnectionTests: XCTestCase {
    func testSharedWindowsAndMacSessionAndOutcomeFixtures() throws {
        let sessions = try DshConnection.parseSessions(XCTUnwrap(try Self.fixture("sessions") as? [String: Any]))
        XCTAssertEqual(sessions.map(\.id), ["running", "idle", "cold", "untitled", "unknown"])
        XCTAssertEqual(sessions[0].workingDirectory, "/Users/demo/Project with spaces")
        XCTAssertEqual(sessions[1].workingDirectory, #"C:\Users\demo\Project with spaces"#)
        XCTAssertEqual(sessions[1].status, .unknown)
        let outcomes = try XCTUnwrap(try Self.fixture("outcomes") as? [[String: Any]])
        for outcome in outcomes {
            let page = try XCTUnwrap(outcome["page"] as? [String: Any])
            let expected = (outcome["status"] as? String).flatMap(TaskStatus.init(rawValue:))
            XCTAssertEqual(try DshConnection.completionStatus(page), expected, outcome["name"] as? String ?? "")
        }
    }

    func testOfficialWalletUsesSharedCurrencyAndPrecisionFixture() async throws {
        let wallet = try XCTUnwrap(try Self.fixture("wallet") as? [String: Any])
        DshConnectionFixture.respond = { request in
            let envelope = try DshConnectionFixture.envelope(request)
            if envelope["method"] as? String == "account/getState" {
                return try DshConnectionFixture.reply(envelope, value: ["status": "credential-stored"])
            }
            XCTAssertEqual(envelope["method"] as? String, "account/getBalance")
            return try DshConnectionFixture.reply(envelope, value: wallet)
        }
        defer { DshConnectionFixture.respond = nil }
        let connection = try DshConnection(authorization: Self.authorization, configuration: Self.configuration)
        let usage = try await connection.officialBalance(billing: "Fixture route")
        XCTAssertEqual(usage.metrics.map(\.label), ["充值余额", "充值余额", "赠送余额"])
        XCTAssertEqual(usage.metrics.map(\.value), ["CNY 12.34567890123456789", "USD 0", "CNY 1.2"])
        XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil })
    }

    func testAuthorizationURLAllowsOnlyOneTokenOnLocalWebRoot() throws {
        for value in ["http://127.0.0.1:3080/?token=fixture", "http://localhost:3080/?token=fixture", "http://[::1]:3080/?token=fixture"] {
            XCTAssertNotNil(try DshConnection.validateURL(value))
        }
        for value in [
            "https://127.0.0.1/?token=fixture", "http://example.com/?token=fixture",
            "http://127.0.0.1.example.com/?token=fixture", "http://user@localhost/?token=fixture",
            "http://localhost/api?token=fixture", "http://localhost/", "http://localhost/?token=",
            "http://localhost/?token=a&token=b", "http://localhost/?token=a&extra=b", "http://localhost/?token=a#fragment"
        ] {
            XCTAssertThrowsError(try DshConnection.validateURL(value), value) {
                XCTAssertFalse($0.localizedDescription.contains("fixture"))
            }
        }
    }

    func testRootMetadataFiltersBlankSessionsBeforeTheDisplayLimit() throws {
        var items: [[String: Any]] = (0..<45).map {
            ["sessionId": "blank-\($0)", "updatedAt": 1791552300000 + $0, "blank": true, "running": false]
        }
        items += [
            ["sessionId": "active", "updatedAt": 1791551800000, "blank": true, "running": true,
             "cwd": "/tmp/fixture project", "projections": ["values": ["title": "Current title"]]],
            ["sessionId": "idle", "updatedAt": 1791551700000, "running": false, "agentAvailable": true],
            ["sessionId": "cold", "updatedAt": 1791551600000, "running": false, "agentAvailable": false],
            ["sessionId": "unknown", "updatedAt": 1791551500000],
            ["sessionId": "child", "parentSessionId": "active", "updatedAt": 1791552000000, "running": true],
            ["sessionId": "subagent", "origin": "subagent", "updatedAt": 1791552000000, "running": true]
        ]
        let sessions = try DshConnection.parseSessions(["items": items])
        XCTAssertEqual(sessions.map(\.id), ["active", "idle", "cold", "unknown"])
        XCTAssertEqual(sessions.first?.title, "Current title")
        XCTAssertEqual(sessions.first?.workingDirectory, "/tmp/fixture project")
        XCTAssertEqual(sessions.first?.status, .running)
        XCTAssertEqual(sessions[1].title, "未命名会话")
        XCTAssertEqual(sessions[1].statusLabel, "空闲")
        XCTAssertEqual(sessions[2].statusLabel, "未运行")
        XCTAssertEqual(sessions[3].statusLabel, "状态未知")
        XCTAssertTrue(sessions.dropFirst().allSatisfy { $0.status == .unknown })
    }

    func testOnlyAnExplicitCompletedEndProducesSuccess() throws {
        let outcomes: [(String, TaskStatus)] = [
            ("completed", .completed), ("aborted", .interrupted), ("interrupted", .interrupted),
            ("forked", .interrupted), ("error", .failed), ("blocked", .failed),
            ("max-tokens", .failed), ("future-reason", .unknown)
        ]
        for (reason, expected) in outcomes {
            XCTAssertEqual(try DshConnection.completionStatus(["records": [Self.end(reason)]]), expected)
        }
        XCTAssertNil(try DshConnection.completionStatus(["records": []]))
        XCTAssertEqual(try DshConnection.completionStatus(["records": [Self.end("completed"),
            ["type": "event", "event": ["type": "turn/start", "data": ["turn": 2]]]]]), .interrupted)
        XCTAssertThrowsError(try DshConnection.completionStatus([:]))
    }

    func testAuthenticationExchangesTokenForCookieAndUsesNamedRPCEnvelope() async throws {
        var authenticated = false
        DshConnectionFixture.respond = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.query, "token=fixture-token")
                authenticated = true
                return (303, ["Set-Cookie": "dsh-auth-fixture=fixture-cookie; Path=/; HttpOnly"], Data())
            }
            XCTAssertTrue(authenticated)
            XCTAssertEqual(request.url?.path, "/api/session/list")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "dsh-auth-fixture=fixture-cookie")
            let envelope = try DshConnectionFixture.envelope(request)
            XCTAssertEqual(envelope["type"] as? String, "client-request")
            XCTAssertEqual(envelope["method"] as? String, "session/list")
            let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
            let args = try XCTUnwrap(payload["args"] as? [String: Any])
            XCTAssertNotNil(args["_request"] as? [String: Any])
            return try DshConnectionFixture.reply(envelope, value: ["items": [Self.session(running: true)]])
        }
        defer { DshConnectionFixture.respond = nil }
        let connection = try DshConnection(authorization: .init(url: "http://127.0.0.1:3080/?token=fixture-token"),
                                           configuration: Self.configuration)
        try await connection.authenticate()
        XCTAssertEqual(connection.authorization.cookie, "dsh-auth-fixture=fixture-cookie")
        let sessions = try await connection.sessions()
        XCTAssertEqual(sessions.first?.status, .running)
    }

    func testHistoryOutcomeIsCachedByCursorButALaterRunningTurnWins() async throws {
        var running = false
        var startDuringPage = false
        var cursor = 12
        var pages = 0
        DshConnectionFixture.respond = { request in
            let envelope = try DshConnectionFixture.envelope(request)
            let method = envelope["method"] as? String
            let value: [String: Any]
            switch method {
            case "session/list": value = ["items": [Self.session(running: running)]]
            case "session/projections": value = ["asOfSeq": cursor, "values": ["inbox": ["next-turn": [], "next-step": []]]]
            case "session/page":
                pages += 1
                let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
                let args = try XCTUnwrap(payload["args"] as? [String: Any])
                let query = try XCTUnwrap(args["request"] as? [String: Any])
                XCTAssertEqual(query["maxMessages"] as? Int, 1)
                XCTAssertEqual(query["throughSeq"] as? Int, cursor)
                if startDuringPage { running = true }
                value = ["records": [Self.end("completed")]]
            default: throw URLError(.unsupportedURL)
            }
            return try DshConnectionFixture.reply(envelope, value: value)
        }
        defer { DshConnectionFixture.respond = nil }
        let connection = try DshConnection(authorization: Self.authorization, configuration: Self.configuration)
        let first = try await connection.sessions()
        let second = try await connection.sessions()
        XCTAssertEqual(first.first?.status, .completed)
        XCTAssertEqual(second.first?.status, .completed)
        XCTAssertEqual(pages, 1)
        cursor += 1
        startDuringPage = true
        let current = try await connection.sessions()
        XCTAssertEqual(current.first?.status, .running)
        XCTAssertEqual(pages, 2)
    }

    func testRPCFailuresAndMismatchedCorrelationNeverBecomeEmptySuccess() async throws {
        for failure in ["http", "id", "business"] {
            DshConnectionFixture.respond = { request in
                let envelope = try DshConnectionFixture.envelope(request)
                if failure == "http" { return (401, [:], Data("fixture-secret".utf8)) }
                let body: [String: Any] = ["type": "server-response", "rpcId": failure == "id" ? "wrong-id" : envelope["rpcId"]!,
                                           "result": ["ok": failure != "business", "value": ["items": []], "error": "fixture-secret"]]
                return (200, [:], try JSONSerialization.data(withJSONObject: body))
            }
            let connection = try DshConnection(authorization: Self.authorization, configuration: Self.configuration)
            do { _ = try await connection.sessions(); XCTFail("\(failure) was accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        }
        DshConnectionFixture.respond = nil
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DshConnectionFixture.self]
        return configuration
    }
    private static var authorization: DshAuthorization {
        .init(url: "http://127.0.0.1:3080/?token=fixture-token", cookie: "dsh-auth-fixture=fixture-cookie")
    }
    private static func session(running: Bool) -> [String: Any] {
        ["sessionId": "fixture", "updatedAt": 1791552000000, "running": running, "agentAvailable": true,
         "projections": ["values": ["title": "Fixture task"]]]
    }
    private static func end(_ reason: String) -> [String: Any] {
        ["type": "event", "event": ["type": "turn/end", "data": ["reason": ["kind": reason]]]]
    }
    private static func fixture(_ name: String) throws -> Any {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/fixtures/dsh/\(name).json")))
    }
}

private final class DshConnectionFixture: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond else { throw URLError(.resourceUnavailable) }
            let (status, headers, body) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func envelope(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func reply(_ request: [String: Any], value: [String: Any]) throws -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: [
            "type": "server-response", "rpcId": request["rpcId"]!, "result": ["ok": true, "value": value]
        ]))
    }
}
