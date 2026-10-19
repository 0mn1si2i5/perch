import XCTest
@testable import PerchCore

final class AntigravityCLIUsageTests: XCTestCase {
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
        let usage = try AntigravityCLIUsage.parse(data(payload), now: now)
        XCTAssertEqual(usage.metrics.count, 2)
        XCTAssertEqual(usage.metrics[0].label, "Gemini Models · 5 小时")
        XCTAssertEqual(usage.metrics[0].remainingPercent, 75)
        XCTAssertNotNil(usage.metrics[0].resetsAt)
        XCTAssertEqual(usage.metrics[1].remainingPercent, 0)
        XCTAssertEqual(usage.observedAt, now)
        XCTAssertTrue(usage.authenticationVerified)
        XCTAssertThrowsError(try AntigravityCLIUsage.parse(data(["status": "SUCCESS", "response": "75% remaining"])))
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
        let usage = try AntigravityCLIUsage.parse(response(buckets))
        XCTAssertEqual(usage.metrics.count, 1)
        XCTAssertEqual(usage.metrics[0].label, "Gemini Models · 5 小时")
        XCTAssertEqual(usage.metrics[0].remainingPercent, 60)
        XCTAssertThrowsError(try AntigravityCLIUsage.parse(response(Array(buckets.dropFirst()))))
    }

    func testAntigravityLabelsArgonWeeklyAsItsOwnPool() throws {
        let payload: [String: Any] = ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [
            ["name": "Gemini Models", "buckets": [["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.96]]],
            ["name": "Gemini 4 Argon", "buckets": [["id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.98]]]
        ]]]]
        let usage = try AntigravityCLIUsage.parse(data(payload))
        XCTAssertEqual(usage.metrics.map(\.label), ["Gemini Models · 每周", "Argon · 每周"])
    }

    func testAntigravityRejectsNondefaultProfile() async throws {
        let root = try fixture()
        let account = Account(id: "other", name: "Other", app: .antigravity, profilePath: root.path,
            sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil,
            localProvider: .init(kind: .terminal, target: "/nonexistent/agy"))
        do {
            _ = try await AntigravityCLIUsage.query(account)
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
        let usage = try await AntigravityCLIUsage.query(account)
        XCTAssertEqual(usage.metrics.first?.remainingPercent, 100)
    }
}
