import XCTest
@testable import PerchCore

final class NativeGeminiUsageTests: XCTestCase {
    func testFindsOnlyOwnedHostAuthenticatedNativeHelper() {
        let app = "/Applications/Gemini.app/Contents/MacOS/Gemini"
        let helper = "/Applications/Gemini.app/Contents/Helpers/agy"
        let flags = "--hub --hub-port=59805 --use_host_auth --host_bridge_url=http://127.0.0.1:50781 --read_host_bridge_token_from_stdin --app_data_dir=antigravity"
        let valid = "100 1 501 \(app)\n101 100 501 \(helper) \(flags)"
        XCTAssertEqual(NativeGeminiUsage.helperCandidates(snapshot: valid, helper: helper, appExecutable: app, uid: 501),
                       [.init(pid: 101, parent: 100, port: 59805)])
        for invalid in [valid.replacingOccurrences(of: "101 100 501", with: "101 100 502"),
                        valid.replacingOccurrences(of: "101 100 501", with: "101 999 501"),
                        valid.replacingOccurrences(of: "http://127.0.0.1", with: "http://remote.example"),
                        valid.replacingOccurrences(of: "--use_host_auth", with: ""),
                        valid.replacingOccurrences(of: "--hub-port=59805", with: "--hub-port=99999"),
                        valid.replacingOccurrences(of: "--app_data_dir=antigravity", with: "--app_data_dir=other")] {
            XCTAssertTrue(NativeGeminiUsage.helperCandidates(snapshot: invalid, helper: helper, appExecutable: app, uid: 501).isEmpty)
        }
    }

    func testNativeQuotaMatchesGeminiOnlyUIAndRejectsInvalidFractions() throws {
        let body = try data(["response": ["groups": [["displayName": "Gemini Models", "buckets": [
            ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.9, "resetTime": "2026-10-24T12:00:00Z"],
            ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1],
            ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.3],
            ["bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.98],
            ["bucketId": "gemini-bool", "remainingFraction": true],
            ["bucketId": "gemini-invalid", "remainingFraction": 2]
        ]]]]])
        let usage = try NativeGeminiUsage.parseQuota(body)
        XCTAssertEqual(usage.metrics.map(\.remainingPercent), [90, 100, 98])
        XCTAssertEqual(usage.metrics.map(\.label), ["Gemini Models · 每周", "Gemini Models · 5 小时", "Argon · 每周"])
        XCTAssertNotNil(usage.metrics[0].resetsAt)
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertThrowsError(try NativeGeminiUsage.parseQuota(Data("{}".utf8)))
    }

    func testExtractsOnlyBoundedCSRFToken() throws {
        XCTAssertEqual(try NativeGeminiUsage.csrfToken(Data("window.__APP_CONFIG__={\"csrfToken\":\"fixture-csrf\"}".utf8)), "fixture-csrf")
        XCTAssertThrowsError(try NativeGeminiUsage.csrfToken(Data("<html>missing</html>".utf8)))
        XCTAssertThrowsError(try NativeGeminiUsage.csrfToken(Data(repeating: 32, count: 65_537)))
    }

    func testRejectsOtherProfileBeforeAnyConnection() async {
        let account = Account(id: "fixture", name: "Native", app: .custom, profilePath: "/tmp/other-profile",
            sessionRoot: "/tmp/other-profile", createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .application, target: "/Applications/Gemini.app"))
        do { _ = try await NativeGeminiUsage.query(account); XCTFail("Expected unsupported profile") }
        catch { XCTAssertTrue(error.localizedDescription.contains("默认登录目录")) }
    }

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
