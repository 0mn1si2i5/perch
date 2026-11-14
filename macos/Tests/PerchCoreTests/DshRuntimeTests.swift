import Foundation
import XCTest
@testable import PerchCore

final class DshRuntimeTests: XCTestCase {
    func testCanonicalHomeSharesLeaseButExternalAccountsStaySeparate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        var first = account(home: home.path, mode: .npm)
        var second = account(home: alias.path, mode: .source)
        XCTAssertEqual(DshState.key(for: first), DshState.key(for: second))
        first.dshWeb?.mode = .external; second.dshWeb?.mode = .external
        XCTAssertNotEqual(DshState.key(for: first), DshState.key(for: second))
    }

    func testLeaseRejectsDuplicateHostAndReleasesOnExit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try DshState(root: root, key: String(repeating: "a", count: 64), lockRoot: root.appendingPathComponent("locks"))
        try state.prepare()
        var first: DshLease? = try DshLease(url: state.lockURL)
        XCTAssertTrue(try XCTUnwrap(first).acquired)
        XCTAssertTrue(state.hostAlive())
        XCTAssertFalse(try DshLease(url: state.lockURL).acquired)
        first = nil
        XCTAssertFalse(state.hostAlive())
        XCTAssertTrue(try DshLease(url: state.lockURL).acquired)
    }

    func testRuntimeAndStopRequestContainNoAuthorizationAndStopOnlyTheirGeneration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try DshState(root: root, key: String(repeating: "b", count: 64), lockRoot: root.appendingPathComponent("locks"))
        let runtime = DshRuntime(phase: "ready", hostPID: 123, childPID: 456, childIdentity: "fixture",
                                 origin: "http://127.0.0.1:12345/")
        try state.write(runtime)
        XCTAssertEqual(try state.read(), runtime)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state.runtimeURL)) as? [String: Any])
        XCTAssertNil(json["authorization"])
        XCTAssertNil(json["cookie"])
        XCTAssertNil(json["url"])
        let mode = try FileManager.default.attributesOfItem(atPath: state.runtimeURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try state.requestStop(runtime)
        XCTAssertTrue(state.stopRequested(runtime))
        XCTAssertFalse(state.stopRequested(.init(phase: "starting")))
        XCTAssertThrowsError(try DshState(root: root, key: "../other"))
    }

    func testStartupParserAcceptsOnlyBoundedLoopbackAnnouncements() {
        XCTAssertEqual(DshHost.announcedURL("dsh web: http://127.0.0.1:12345/?token=synthetic"),
                       "http://127.0.0.1:12345/?token=synthetic")
        XCTAssertNil(DshHost.announcedURL("request body http://127.0.0.1:12345/?token=synthetic"))
        XCTAssertNil(DshHost.announcedURL("dsh web: http://example.com/?token=synthetic"))
        XCTAssertNil(DshHost.announcedURL("dsh web: http://127.0.0.1:12345/?token=" + String(repeating: "x", count: 8192)))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-runtime-" + UUID().uuidString)
    }
    private func account(home: String, mode: DshMode) -> Account {
        .init(id: UUID().uuidString, name: "fixture", app: .deepseek, profilePath: home, sessionRoot: home,
              createdAt: Date(), lastLaunchedAt: nil, dshWeb: .init(mode: mode))
    }
}

final class DshServiceTests: XCTestCase {
    func testReconnectCannotBorrowPreviousInstancesWalletAndPersistsOnlyInCredentialStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-service-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryDshCredentials()
        let service = makeService(root: root, credentials: credentials)
        let account = account(root: root)
        try await service.connect(account: account, url: "http://127.0.0.1:12345/?token=A")
        let first = await service.balances(account: account, manual: true)
        XCTAssertEqual(first.official?.metrics.first?.value, "CNY 25.5")
        XCTAssertNil(first.officialError)
        try await service.connect(account: account, url: "http://127.0.0.1:12345/?token=B")
        let second = await service.balances(account: account, manual: true)
        XCTAssertNil(second.official, "A different instance must not inherit A's cached wallet")
        XCTAssertNotNil(second.officialError)
        let state = try DshState(root: root, key: DshState.key(for: account), lockRoot: root.appendingPathComponent("test-locks"))
        let text = try String(contentsOf: state.runtimeURL, encoding: .utf8)
        XCTAssertFalse(text.contains("token=")); XCTAssertFalse(text.contains("cookie"))
        XCTAssertEqual(try credentials.read(state.credentialKey)?.cookie, "dsh_session=B")
        let restored = makeService(root: root, credentials: credentials)
        let snapshot = await restored.read(account: account)
        XCTAssertTrue(snapshot.running)
        XCTAssertFalse(credentials.interactions.last ?? true, "Background reads must never prompt for Keychain access")
        _ = try await restored.ensure(account: account)
        XCTAssertTrue(credentials.interactions.last ?? false, "Explicit opening can request Keychain consent after an app update")
        try await restored.stop(account: account)
        XCTAssertNil(try credentials.read(state.credentialKey))
        XCTAssertEqual(try state.read()?.phase, "disconnected")
    }

    func testRuntimeIdentityReplacementInvalidatesWalletEvenWhenAuthorizationMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryDshCredentials()
        let service = makeService(root: root, credentials: credentials)
        let account = account(root: root)
        try await service.connect(account: account, url: "http://127.0.0.1:12345/?token=A")
        let initial = await service.balances(account: account, manual: true)
        XCTAssertNotNil(initial.official)
        let state = try DshState(root: root, key: DshState.key(for: account), lockRoot: root.appendingPathComponent("test-locks"))
        var runtime = try XCTUnwrap(state.read())
        runtime.instance = UUID().uuidString
        try state.write(runtime)
        // A replacement process with the same synthetic authorization now has a failing wallet endpoint.
        RuntimeRPC.failWallet = true
        defer { RuntimeRPC.failWallet = false }
        let result = await service.balances(account: account, manual: true)
        XCTAssertNil(result.official)
        XCTAssertNotNil(result.officialError)
    }

    func testManagedAccountCannotTakeOverAnUntrackedExternalURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-managed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryDshCredentials()
        let service = makeService(root: root, credentials: credentials)
        var account = account(root: root)
        account.dshWeb?.mode = .npm
        do {
            try await service.connect(account: account, url: "http://127.0.0.1:12345/?token=A")
            XCTFail("A managed account must not adopt an untracked process")
        } catch { XCTAssertTrue(error.localizedDescription.contains("连接已有实例")) }
        let state = try DshState(root: root, key: DshState.key(for: account), lockRoot: root.appendingPathComponent("test-locks"))
        XCTAssertNil(try state.read())
        XCTAssertNil(try credentials.read(state.credentialKey))
    }

    private func makeService(root: URL, credentials: MemoryDshCredentials) -> DshService {
        DshService(root: root, credentials: credentials) { authorization in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RuntimeRPC.self]
            return try DshConnection(authorization: authorization, configuration: configuration)
        }
    }
    private func account(root: URL) -> Account {
        .init(id: UUID().uuidString, name: "fixture", app: .deepseek, profilePath: root.appendingPathComponent("home").path,
              sessionRoot: root.appendingPathComponent("home").path, createdAt: Date(), lastLaunchedAt: nil,
              dshWeb: .init(mode: .external))
    }
}

private final class MemoryDshCredentials: DshAuthorizationStorage {
    private let lock = NSLock()
    private var values: [String: DshAuthorization] = [:]
    private var recordedInteractions: [Bool] = []
    var interactions: [Bool] { lock.withLock { recordedInteractions } }
    func read(_ key: String, interactive: Bool) throws -> DshAuthorization? {
        lock.withLock { recordedInteractions.append(interactive); return values[key] }
    }
    func write(_ value: DshAuthorization, key: String, interactive: Bool) throws { lock.withLock { values[key] = value } }
    func remove(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class RuntimeRPC: URLProtocol {
    private static let lock = NSLock()
    private static var storedFailWallet = false
    static var failWallet: Bool {
        get { lock.withLock { storedFailWallet } }
        set { lock.withLock { storedFailWallet = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "GET" {
                let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
                reply(status: 200, headers: ["Set-Cookie": "dsh_session=\(token); Path=/"], body: Data())
                return
            }
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            } else { data = Data() }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = body["method"] as? String ?? ""
            let value: Any
            switch method {
            case "session/list": value = ["items": []]
            case "session/modelCatalog": value = ["default": ["provider": "deepseek-account"]]
            case "account/getState": value = ["status": "credential-stored"]
            case "account/getBalance":
                if Self.failWallet || request.value(forHTTPHeaderField: "Cookie") == "dsh_session=B" {
                    reply(status: 500, body: Data()); return
                }
                value = ["status": "ready", "value": [["currency": "CNY", "balance": "25.5"]], "bonusWallets": []]
            default: throw DshError.invalid("Unexpected fixture RPC")
            }
            let response: [String: Any] = ["type": "server-response", "rpcId": body["rpcId"] ?? "", "result": ["ok": true, "value": value]]
            reply(status: 200, body: try JSONSerialization.data(withJSONObject: response))
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func reply(status: Int, headers: [String: String] = [:], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
