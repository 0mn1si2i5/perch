import Foundation
import XCTest
@testable import PerchCore

final class DshApiBalanceTests: XCTestCase {
    func testUsesTheAdvertisedReferenceAndThrottlesUnchangedCredentials() async throws {
        let root = try Self.home()
        defer { try? FileManager.default.removeItem(at: root); DshBalanceFixture.respond = nil }
        try Self.credentials("named-fixture-key", at: root)
        var requests = 0
        DshBalanceFixture.respond = { request in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer named-fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, Self.balance)
        }
        let reader = DshApiBalance(configuration: Self.configuration)
        let first = await reader.read(route: Self.route(), home: root.path)
        let second = await reader.read(route: Self.route(), home: root.path)
        XCTAssertNil(first.error)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.usage?.metrics.first?.value, "CNY 4.5")
        XCTAssertEqual(first.usage?.metrics.map(\.label), ["API 余额", "充值余额", "赠送余额"])
        XCTAssertEqual(first.usage?.metrics.map(\.value), ["CNY 4.5", "CNY 4", "CNY 0.5"])
        XCTAssertEqual(requests, 1)
    }

    func testCredentialScalarTypesAreNotCoercedIntoKeys() throws {
        for text in [
            #"{"version":1,"refs":{"NAMED_DSH_KEY":123}}"#,
            #"{"version":1,"refs":{"NAMED_DSH_KEY":true}}"#,
            #"{"version":true,"refs":{"NAMED_DSH_KEY":"fixture"}}"#,
            "version: 1\nrefs:\n  NAMED_DSH_KEY: 123\n",
            "version: 1\nrefs:\n  NAMED_DSH_KEY: true\n",
            "version: 1\nrefs:\n  NAMED_DSH_KEY: null\n"
        ] {
            XCTAssertThrowsError(try DeepSeekUsage.apiKey(credentialData: Data(text.utf8), reference: "NAMED_DSH_KEY"))
        }
        XCTAssertEqual(try DeepSeekUsage.apiKey(credentialData: Data("version: 1\nrefs:\n  NAMED_DSH_KEY: '123'\n".utf8),
                                              reference: "NAMED_DSH_KEY"), "123")
    }

    func testRotatedKeyFailureCannotReuseThePreviousWallet() async throws {
        let root = try Self.home()
        defer { try? FileManager.default.removeItem(at: root); DshBalanceFixture.respond = nil }
        try Self.credentials("original-fixture-key", at: root)
        var requests = 0
        DshBalanceFixture.respond = { request in
            requests += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer original-fixture-key" { return (200, Self.balance) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer replacement-fixture-key")
            return (401, Data("fixture-secret-error".utf8))
        }
        let reader = DshApiBalance(configuration: Self.configuration)
        let first = await reader.read(route: Self.route(), home: root.path)
        XCTAssertNotNil(first.usage)
        try Self.credentials("replacement-fixture-key", at: root)
        let changed = await reader.read(route: Self.route(), home: root.path)
        XCTAssertNil(changed.usage)
        XCTAssertNotNil(changed.error)
        XCTAssertFalse(changed.error?.contains("fixture") ?? false)
        XCTAssertEqual(requests, 2)
    }

    func testSameIdentityFailureKeepsTimestampedWalletButClearForgetsIt() async throws {
        let root = try Self.home()
        defer { try? FileManager.default.removeItem(at: root); DshBalanceFixture.respond = nil }
        try Self.credentials("fixture-key", at: root)
        var status = 200
        DshBalanceFixture.respond = { _ in (status, status == 200 ? Self.balance : Data("raw-fixture-error".utf8)) }
        let reader = DshApiBalance(configuration: Self.configuration)
        let first = await reader.read(route: Self.route(), home: root.path)
        status = 500
        let failed = await reader.read(route: Self.route(), home: root.path, manual: true)
        XCTAssertEqual(failed.usage, first.usage)
        XCTAssertNotNil(failed.error)
        XCTAssertFalse(failed.error?.contains("fixture") ?? false)
        reader.clear()
        let cleared = await reader.read(route: Self.route(), home: root.path, manual: true)
        XCTAssertNil(cleared.usage)
    }

    func testUnsupportedRoutesAndMissingReferencesNeverSendDefaultKey() async throws {
        let root = try Self.home()
        defer { try? FileManager.default.removeItem(at: root); DshBalanceFixture.respond = nil }
        try Data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: default-fixture-key\n".utf8)
            .write(to: root.appendingPathComponent(".credentials.yaml"))
        var requests = 0
        DshBalanceFixture.respond = { _ in requests += 1; return (200, Self.balance) }
        let reader = DshApiBalance(configuration: Self.configuration)
        for route in [
            Self.route(provider: "custom-gateway"), Self.route(configured: false), Self.route(source: "environment"),
            Self.route(baseURL: "https://gateway.invalid"), Self.route(baseURL: "http://api.deepseek.com"),
            Self.route(baseURL: "https://api.deepseek.com.evil.invalid"), Self.route(reference: "MISSING_KEY"),
            Self.route(reference: "../DEEPSEEK_API_KEY")
        ] {
            let result = await reader.read(route: route, home: root.path)
            XCTAssertNil(result.usage)
        }
        XCTAssertEqual(requests, 0)
    }

    func testRedirectAndMalformedWalletNeverBecomeSuccessfulZeroBalance() async throws {
        let root = try Self.home()
        defer { try? FileManager.default.removeItem(at: root); DshBalanceFixture.respond = nil }
        try Self.credentials("fixture-key", at: root)
        for (status, body) in [
            (302, Self.balance),
            (200, Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)),
            (200, Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"NaN"}]}"#.utf8)),
            (200, Data(#"{"is_available":1,"balance_infos":[{"currency":"CNY","total_balance":"4.5","topped_up_balance":"4","granted_balance":"0.5"}]}"#.utf8)),
            (200, Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"4.5","topped_up_balance":"4","granted_balance":"0.5"},{"currency":"CNY","total_balance":"1","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8))
        ] {
            DshBalanceFixture.respond = { _ in (status, body) }
            let reader = DshApiBalance(configuration: Self.configuration)
            let result = await reader.read(route: Self.route(), home: root.path)
            XCTAssertNil(result.usage)
            XCTAssertNotNil(result.error)
        }
    }

    private static func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-balance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private static func credentials(_ key: String, at root: URL) throws {
        try Data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: ignored-fixture-key\n  NAMED_DSH_KEY: '\(key)'\n".utf8)
            .write(to: root.appendingPathComponent(".credentials.yaml"), options: .atomic)
    }
    private static func route(provider: String = "deepseek-official", reference: String = "NAMED_DSH_KEY",
                              configured: Bool = true, source: String = "file", baseURL: String = "https://api.deepseek.com/anthropic") -> DshBilling {
        .init(detail: "Fixture billing", provider: provider, reference: reference, configured: configured, source: source, baseURL: baseURL)
    }
    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DshBalanceFixture.self]
        return configuration
    }
    private static let balance = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"4.50","topped_up_balance":"4.00","granted_balance":"0.50"}]}"#.utf8)
}

private final class DshBalanceFixture: URLProtocol {
    static var respond: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.respond else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let (status, body) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
