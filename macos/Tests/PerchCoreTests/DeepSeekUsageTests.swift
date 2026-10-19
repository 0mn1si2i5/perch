import Foundation
import XCTest
@testable import PerchCore

final class DeepSeekUsageTests: XCTestCase {
    private let credentials = """
    version: 1
    records:
      client-connection/browser-session:
        kind: grant
        payload:
          version: 1
          secret: browser-fixture
      deepseek-account-platform/default:
        kind: grant
        payload:
          version: 1
          token: "platform-fixture"
          issuer: https://platform.deepseek.com
    refs:
      DEEPSEEK_API_KEY: api-fixture
    """

    func testPlatformGrantTakesPrecedenceOverBrowserSecretAndAPIKey() throws {
        let credential = try DeepSeekUsage.parseCredential(Data(credentials.utf8))
        XCTAssertEqual(credential, .platform("platform-fixture"))
        let request = DeepSeekUsage.makeRequest(credential)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.deepseek.com/api/v0/users/get_user_summary")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-dsh-auth-token"), "platform-fixture")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

    func testAPIKeyOnlyCredentialsUseOfficialBalanceEndpoint() throws {
        let credential = try DeepSeekUsage.parseCredential(Data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: 'api-fixture'\n".utf8))
        XCTAssertEqual(credential, .apiKey("api-fixture"))
        let request = DeepSeekUsage.makeRequest(credential)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer api-fixture")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-dsh-auth-token"))
    }

    func testRejectsForeignIssuerAmbiguousAndUnsupportedCredentials() {
        for text in [
            credentials.replacingOccurrences(of: "https://platform.deepseek.com", with: "https://foreign.invalid"),
            credentials.replacingOccurrences(of: "token: \"platform-fixture\"", with: "token: \"platform-fixture\"\n      token: second-fixture"),
            credentials.replacingOccurrences(of: "token: \"platform-fixture\"", with: "token: *another-secret"),
            credentials.replacingOccurrences(of: "token: \"platform-fixture\"", with: "token: \"bad\\nheader\""),
            "version: 2\nrefs:\n  DEEPSEEK_API_KEY: api-fixture\n",
            "version: 1\nrecords:\n  client-connection/browser-session:\n    kind: grant\n    payload:\n      secret: browser-fixture\n"
        ] {
            XCTAssertThrowsError(try DeepSeekUsage.parseCredential(Data(text.utf8))) { error in
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertFalse(error.localizedDescription.contains("foreign.invalid"))
            }
        }
    }

    func testJSONIsValidYAMLAndAcceptedWithoutLeakingCredentials() throws {
        let data = Data(#"{"version":1,"records":{"deepseek-account-platform/default":{"kind":"grant","payload":{"version":1,"token":"platform-fixture","issuer":"https://platform.deepseek.com"}}}}"#.utf8)
        XCTAssertEqual(try DeepSeekUsage.parseCredential(data), .platform("platform-fixture"))
    }

    func testWalletsRetainCurrencyAndNeverInventPercentages() throws {
        let data = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"0E-16"},{"currency":"CNY","balance":"20.12340000"}],"bonus_wallets":[{"currency":"CNY","balance":"1.25"}],"total_costs":"ignore"}}}"#.utf8)
        let now = Date(timeIntervalSince1970: 100)
        let usage = try DeepSeekUsage.parseResponse(data, credential: .platform("fixture"), now: now)
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertEqual(usage.observedAt, now)
        XCTAssertEqual(usage.metrics.map(\.label), ["充值余额", "充值余额", "赠送余额"])
        XCTAssertEqual(usage.metrics.map(\.value), ["USD 0", "CNY 20.1234", "CNY 1.25"])
        XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil && $0.resetsAt == nil })
    }

    func testInsufficientAPIBalanceIsAuthenticatedZeroNotSignedOut() throws {
        let data = Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00"}]}"#.utf8)
        let usage = try DeepSeekUsage.parseResponse(data, credential: .apiKey("fixture"), now: Date())
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertEqual(usage.metrics.first?.value, "CNY 0")
        XCTAssertEqual(usage.summary, "DeepSeek API 余额不足")
    }

    func testExpiredMalformedAndBusinessErrorsNeverBecomeZeroBalance() {
        let payloads = [
            #"{"code":40003,"message":"fixture-secret"}"#,
            #"{"code":0,"data":{"biz_code":3,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#,
            #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#,
            #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"NaN"}],"bonus_wallets":[]}}}"#,
            #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"unexpected","balance":"4"}],"bonus_wallets":[]}}}"#
        ]
        for text in payloads {
            XCTAssertThrowsError(try DeepSeekUsage.parseResponse(Data(text.utf8), credential: .platform("fixture"), now: Date())) {
                XCTAssertFalse($0.localizedDescription.contains("fixture-secret"))
            }
        }
    }

    func testQueryUsesInjectedTransportAndSanitizesFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekUsageFixture.self]
        for status in [200, 401, 302, 500] {
            DeepSeekUsageFixture.status = status
            do {
                let result = try await DeepSeekUsage.query(credentialData: Data(credentials.utf8), configuration: configuration)
                XCTAssertEqual(status, 200)
                XCTAssertTrue(result.authenticationVerified)
                XCTAssertEqual(result.metrics.first?.value, "CNY 3")
            } catch {
                XCTAssertNotEqual(status, 200)
                XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
                XCTAssertFalse(error.localizedDescription.contains("platform-fixture"))
            }
        }
    }
}

private final class DeepSeekUsageFixture: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-dsh-auth-token"), "platform-fixture")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.status == 200
            ? #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"3"}],"bonus_wallets":[]}}}"#
            : #"{"error":"fixture-secret"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
