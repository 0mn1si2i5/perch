import XCTest
@testable import PerchCore

final class GoogleProviderUsageTests: XCTestCase {
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAntigravityParsesRemainingFractionsAndRejectsModelText() throws {
        let payload: [String: Any] = ["status": "SUCCESS", "response": "ignored",
            "command": ["name": "usage", "data": ["groups": [["name": "Gemini Models", "buckets": [
                ["id": "gemini-5h", "window": "5h", "remaining_fraction": 0.75, "reset_time": "2026-10-18T12:00:00Z"],
                ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.0],
                ["id": "gemini-invalid", "window": "invalid", "remaining_fraction": 2],
                ["id": "gemini-bool", "window": "invalid-bool", "remaining_fraction": true]
            ]]]]]]
        let now = Date(timeIntervalSince1970: 1000)
        let usage = try GoogleProviderUsage.parseAntigravity(data(payload), now: now)
        XCTAssertEqual(usage.metrics.count, 2)
        XCTAssertEqual(usage.metrics[0].label, "Gemini Models · 5 小时")
        XCTAssertEqual(usage.metrics[0].remainingPercent, 75)
        XCTAssertNotNil(usage.metrics[0].resetsAt)
        XCTAssertEqual(usage.metrics[1].remainingPercent, 0)
        XCTAssertEqual(usage.observedAt, now)
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertThrowsError(try GoogleProviderUsage.parseAntigravity(data(["status": "SUCCESS", "response": "75% remaining"])))
    }


    func testAntigravityOnlyShowsGoogleBucketsEvenWhenOtherModelsAreAvailable() throws {
        let buckets: [[String: Any]] = [
            ["id": "gemini-5h", "window": "5h", "remaining_fraction": 0.6],
            ["id": "3p-5h", "window": "5h", "remaining_fraction": 1.0],
            ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 1.0],
            ["window": "weekly", "remaining_fraction": 1.0]
        ]
        func response(_ buckets: [[String: Any]]) throws -> Data {
            try data(["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [["name": "Any label", "buckets": buckets]]]]])
        }
        let usage = try GoogleProviderUsage.parseAntigravity(response(buckets))
        XCTAssertEqual(usage.metrics.count, 1)
        XCTAssertEqual(usage.metrics[0].label, "Gemini Models · 5 小时")
        XCTAssertEqual(usage.metrics[0].remainingPercent, 60)
        XCTAssertThrowsError(try GoogleProviderUsage.parseAntigravity(response(Array(buckets.dropFirst()))))
    }

    func testGeminiFailureNeverLeaksServerMessageOrMislabelsSignOut() throws {
        let response = try data(["error": ["message": "private-identity-token", "details": [["reason": "SUBSCRIPTION_REQUIRED"]]]])
        XCTAssertThrowsError(try GoogleProviderUsage.check(403, data: response)) { error in
            guard case ProviderUsageError.unsupported(let reason) = error else { return XCTFail("expected migration guidance") }
            XCTAssertTrue(reason.contains("Antigravity"))
            XCTAssertFalse(reason.contains("private-identity-token"))
        }
        XCTAssertThrowsError(try GoogleProviderUsage.check(401, data: response)) { error in
            guard case ProviderUsageError.signedOut = error else { return XCTFail("expected signedOut") }
        }
        XCTAssertThrowsError(try GoogleProviderUsage.check(500, data: response)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-identity-token"))
        }
    }

    func testGeminiRefreshesInMemoryAndUsesProjectForQuota() async throws {
        let root = try fixture()
        let credentialFile = root.appendingPathComponent("oauth_creds.json")
        let credentials = try data(["refresh_token": "fixture-refresh+token", "expiry_date": 0])
        try credentials.write(to: credentialFile)
        try data(["security": ["auth": ["selectedType": "oauth-personal"]]])
            .write(to: root.appendingPathComponent("settings.json"))
        try Data("const OAUTH_CLIENT_ID = 'fixture-client'; const OAUTH_CLIENT_SECRET = 'fixture-registration';".utf8)
            .write(to: root.appendingPathComponent("bundle.js"))
        let account = Account(id: "fixture", name: "Fixture", app: .gemini, profilePath: root.path,
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .terminal, target: root.appendingPathComponent("gemini").path))
        let requests = GoogleUsageRequests()
        GoogleUsageProtocol.handler = { request in
            requests.append(request)
            switch request.url!.absoluteString {
            case "https://oauth2.googleapis.com/token":
                return (200, Data(#"{"access_token":"fixture-access"}"#.utf8))
            case "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist":
                return (200, Data(#"{"cloudaicompanionProject":"fixture-project"}"#.utf8))
            case "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota":
                return (200, Data(#"{"buckets":[{"modelId":"fixture-model","remainingFraction":0.4,"resetTime":"2026-10-18T12:00:00Z"}]}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
        defer { GoogleUsageProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleUsageProtocol.self]
        let usage = try await GoogleProviderUsage(configuration: config).fetch(account)
        XCTAssertEqual(usage.metrics.first?.remainingPercent, 40)
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertEqual(try Data(contentsOf: credentialFile), credentials, "refreshed tokens must not be written back")
        let captured = requests.values
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(captured.allSatisfy { $0.url?.query == nil })
        XCTAssertEqual(captured[2].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured[2].httpBody!) as? [String: String])
        XCTAssertEqual(body["project"], "fixture-project")
        let refresh = String(data: captured[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(refresh.contains("fixture-refresh%2Btoken"))
    }

    func testNativeGeminiDoesNotBorrowCLIQuota() async throws {
        let root = try fixture()
        let account = Account(id: "native", name: "Native", app: .gemini, profilePath: root.path,
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .application, target: "/Applications/Gemini.app"))
        do {
            _ = try await GoogleProviderUsage().fetch(account)
            XCTFail("native Gemini must not use CLI login")
        } catch {
            guard case ProviderUsageError.unsupported = error else { return XCTFail("unexpected error") }
        }
    }

    func testGeminiAPIKeyModeDoesNotReadOldOAuthIdentity() async throws {
        let root = try fixture()
        try data(["security": ["auth": ["selectedType": "gemini-api-key"]]])
            .write(to: root.appendingPathComponent("settings.json"))
        try data(["access_token": "old-oauth", "expiry_date": 9_999_999_999_999])
            .write(to: root.appendingPathComponent("oauth_creds.json"))
        let account = Account(id: "api", name: "Fixture", app: .gemini, profilePath: root.path,
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .terminal, target: root.appendingPathComponent("gemini").path))
        do {
            _ = try await GoogleProviderUsage.query(account)
            XCTFail("must not use stale OAuth identity")
        } catch {
            guard case ProviderUsageError.unsupported(let reason) = error else { return XCTFail("expected unsupported auth mode") }
            XCTAssertTrue(reason.contains("API Key"))
        }
    }

    func testAntigravityRejectsNondefaultProfile() async throws {
        let root = try fixture()
        let account = Account(id: "other", name: "Other", app: .antigravity, profilePath: root.path,
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .terminal, target: "/nonexistent/agy"))
        do {
            _ = try await GoogleProviderUsage.query(account)
            XCTFail("must not return default account quota")
        } catch {
            guard case ProviderUsageError.unsupported(let reason) = error else { return XCTFail("expected unsupported profile") }
            XCTAssertTrue(reason.contains("默认登录目录"))
        }
    }

    func testAntigravityRunsOnlyStructuredUsageCommand() async throws {
        let root = try fixture(), executable = root.appendingPathComponent("agy-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = '-p' ] && [ "$2" = '/usage' ] && [ "$3" = '--output-format' ] && [ "$4" = 'json' ] || exit 9
        printf '%s' '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Fixture","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1}]}]}}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let account = Account(id: "fixture", name: "Fixture", app: .antigravity, profilePath: NSHomeDirectory() + "/.gemini/antigravity-cli",
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .terminal, target: executable.path))
        let usage = try await GoogleProviderUsage.query(account)
        XCTAssertEqual(usage.metrics.first?.remainingPercent, 100)
    }
}

private final class GoogleUsageRequests {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ value: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(value) }
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class GoogleUsageProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let (status, data) = try Self.handler!(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
