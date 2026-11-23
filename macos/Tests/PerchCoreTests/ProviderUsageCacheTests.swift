import XCTest
@testable import PerchCore

final class ProviderUsageCacheTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPersistsLoadsPrunesAndSetsPrivatePermissions() throws {
        let root = try fixture()
        let cache = ProviderUsageCache(root: root)
        let observed = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = Date(timeIntervalSince1970: 1_760_018_000)
        let usage = ProviderUsage(
            metrics: [
                .init(label: "Gemini Models · 5 小时", remainingPercent: 82.5, resetsAt: reset),
                .init(label: "Argon · 每周", remainingPercent: 95, resetsAt: nil)
            ],
            summary: "Antigravity 实时额度",
            observedAt: observed,
            authenticationVerified: true
        )
        cache.save(usage, for: "gemini-1")
        cache.save(usage, for: "old-account")

        let attrs = try FileManager.default.attributesOfItem(atPath: cache.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = ProviderUsageCache(root: root).load()
        XCTAssertEqual(reloaded["gemini-1"], usage)
        XCTAssertEqual(reloaded["old-account"], usage)

        cache.prune(keeping: ["gemini-1"])
        let pruned = ProviderUsageCache(root: root).load()
        XCTAssertEqual(Set(pruned.keys), ["gemini-1"])

        cache.remove(accountID: "gemini-1")
        XCTAssertTrue(ProviderUsageCache(root: root).load().isEmpty)
    }
}
