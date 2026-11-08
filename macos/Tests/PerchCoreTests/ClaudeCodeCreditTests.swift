import Foundation
import XCTest
@testable import PerchCore

final class ClaudeCodeCreditTests: XCTestCase {
    private func line(id: String, model: String, at stamp: String, usage: String) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":\#(usage)}}"#
    }

    private func write(_ lines: [String], to dir: URL, path: String) throws {
        let file = dir.appendingPathComponent("projects").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private let since = ISO8601.parse("2026-11-01T00:00:00.000Z")!

    /// A real Claude Haiku 5.5 run: Claude Code reported total_cost_usd 0.0021318 for these four responses.
    func testMatchesClaudeCodeReportedCostAndCountsEachResponseOnce() throws {
        let dir = try makeTempDir()
        let usages = [
            #"{"input_tokens":2,"cache_creation_input_tokens":6465,"cache_read_input_tokens":10709,"output_tokens":193,"cache_creation":{"ephemeral_5m_input_tokens":6465,"ephemeral_1h_input_tokens":0}}"#,
            #"{"input_tokens":1,"cache_creation_input_tokens":380,"cache_read_input_tokens":17174,"output_tokens":147,"cache_creation":{"ephemeral_5m_input_tokens":380,"ephemeral_1h_input_tokens":0}}"#,
        ]
        let expected = (2 * 0.1 + 193 * 0.5 + 10709 * 0.01 + 6465 * 0.125 + 1 * 0.1 + 147 * 0.5 + 17174 * 0.01 + 380 * 0.125) / 1_000_000
        // Same response id on two lines (one per content block) must count once.
        try write([line(id: "a", model: "claude-haiku-5-5", at: "2026-11-07T16:44:40.000Z", usage: usages[0]),
                   line(id: "a", model: "claude-haiku-5-5", at: "2026-11-07T16:44:40.000Z", usage: usages[0]),
                   line(id: "b", model: "claude-haiku-5-5", at: "2026-11-07T16:44:50.000Z", usage: usages[1])],
                  to: dir, path: "-tmp-x/s1.jsonl")
        let found = ClaudeCodeCredit.estimate(configDir: dir, since: since)
        XCTAssertEqual(found.messages, 2)
        XCTAssertEqual(found.spent, expected, accuracy: 1e-12)
    }

    func testSkipsOldResponsesReadsSubagentsAndReportsUnpricedModels() throws {
        let dir = try makeTempDir()
        let usage = #"{"input_tokens":1000000,"output_tokens":0}"#
        try write([line(id: "old", model: "claude-opus-5-5", at: "2026-10-31T23:59:59.000Z", usage: usage),
                   line(id: "new", model: "claude-opus-5-5", at: "2026-11-02T00:00:00.000Z", usage: usage)],
                  to: dir, path: "-p/s.jsonl")
        try write([line(id: "sub", model: "claude-sonnet-5-5", at: "2026-11-02T00:00:00.000Z", usage: usage),
                   line(id: "x", model: "claude-future-9", at: "2026-11-02T00:00:00.000Z", usage: #"{"input_tokens":5,"output_tokens":5}"#)],
                  to: dir, path: "-p/s/subagents/agent-1.jsonl")
        let found = ClaudeCodeCredit.estimate(configDir: dir, since: since)
        XCTAssertEqual(found.spent, 4 + 2, accuracy: 1e-9)
        XCTAssertEqual(found.unpriced, ["claude-future-9"])
    }

    func testPriceLookupLongPromptFastModeAndSearches() {
        XCTAssertEqual(ClaudeCodeCredit.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(ClaudeCodeCredit.price(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(ClaudeCodeCredit.price(for: "claude-opus-5-5[1m]")?.input, 4)
        XCTAssertNil(ClaudeCodeCredit.price(for: "<synthetic>"))
        let long = ClaudeCodeCredit.cost(["input_tokens": 200_000], model: "claude-haiku-5-5")!
        XCTAssertEqual(long, 200_000 * 0.5 / 1_000_000, accuracy: 1e-12)
        let fast = ClaudeCodeCredit.cost(["output_tokens": 1_000_000, "speed": "fast"], model: "claude-opus-5-5")!
        XCTAssertEqual(fast, 40, accuracy: 1e-9)
        let search = ClaudeCodeCredit.cost(["server_tool_use": ["web_search_requests": 3]], model: "claude-sonnet-5-5")!
        XCTAssertEqual(search, 0.03, accuracy: 1e-12)
    }

    func testParsesConsoleGrantsAndRejectsBadLines() {
        let grants = CreditGrant.parse("$157.94 2026-11-06 2026-12-09\n\n100, 2026-10-29, 2026-11-22\n")
        XCTAssertEqual(grants, [.init(amount: 157.94, grantedOn: "2026-11-06", expiresOn: "2026-12-09"),
                                .init(amount: 100, grantedOn: "2026-10-29", expiresOn: "2026-11-22")])
        XCTAssertEqual(CreditGrant.parse(""), [])
        XCTAssertNil(CreditGrant.parse("100 2026-11-22 2026-10-29"))
        XCTAssertNil(CreditGrant.parse("100 2026-13-01 2026-12-01"))
        XCTAssertNil(CreditGrant.parse("100 2026-11-01"))
        XCTAssertEqual(CreditGrant.parse(CreditGrant.format(grants!)), grants)
        // The expiry day is still usable (UTC).
        XCTAssertEqual(grants![1].end, ISO8601.parse("2026-11-23T00:00:00.000Z"))
    }

    func testChargesDrawFromEarliestExpiringGrantInEffect() {
        let older = CreditGrant(amount: 100, grantedOn: "2026-10-29", expiresOn: "2026-11-22")
        let newer = CreditGrant(amount: 157.94, grantedOn: "2026-11-06", expiresOn: "2026-12-09")
        let at = { (s: String) in ISO8601.parse(s)! }
        let charges = [ClaudeCodeCredit.Charge(at: at("2026-11-08T00:00:00.000Z"), cost: 30),
                       ClaudeCodeCredit.Charge(at: at("2026-11-20T00:00:00.000Z"), cost: 90),   // 70 from older, 20 from newer
                       ClaudeCodeCredit.Charge(at: at("2026-11-30T00:00:00.000Z"), cost: 10),   // older has expired
                       ClaudeCodeCredit.Charge(at: at("2026-12-20T00:00:00.000Z"), cost: 5)]    // nothing in effect
        let result = ClaudeCodeCredit.allocate(charges, to: [newer, older])
        XCTAssertEqual(result.remaining[0], 127.94, accuracy: 1e-9)
        XCTAssertEqual(result.remaining[1], 0, accuracy: 1e-9)
        XCTAssertEqual(result.uncovered, 5, accuracy: 1e-9)
    }

    func testQueryShowsOnlyGrantsInEffect() async throws {
        let dir = try makeTempDir()
        try write([line(id: "a", model: "claude-opus-5-5", at: "2026-11-08T00:00:00.000Z", usage: #"{"input_tokens":1000000,"output_tokens":0}"#)],
                  to: dir, path: "-p/s.jsonl")
        var account = Account(id: "a", name: "org", app: .claudeCode, profilePath: dir.path, sessionRoot: dir.path,
                              createdAt: Date(), lastLaunchedAt: nil)
        account.creditGrants = [.init(amount: 100, grantedOn: "2026-10-29", expiresOn: "2026-11-22"),
                                .init(amount: 157.94, grantedOn: "2026-11-06", expiresOn: "2026-12-09")]
        let before = try await ClaudeCodeCredit.query(account, now: ISO8601.parse("2026-11-10T00:00:00.000Z")!)
        XCTAssertEqual(before.metrics.map(\.label), ["已用", "估算剩余", "2026-11-22 到期", "2026-12-09 到期"])
        XCTAssertEqual(before.metrics[1].value, "$253.94 / $257.94")
        XCTAssertEqual(before.metrics[2].value, "$96.00 / $100.00")
        let after = try await ClaudeCodeCredit.query(account, now: ISO8601.parse("2026-11-25T00:00:00.000Z")!)
        XCTAssertEqual(after.metrics[1].value, "$157.94 / $157.94")
        XCTAssertEqual(after.metrics.count, 3)
    }

    func testScanFindsPerchClaudeDirsAndLauncherSetsConfigDirs() throws {
        let home = try makeTempDir()
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let org = home.appendingPathComponent(".perch/claude/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try "{}".write(to: org.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".perch/claude/empty"), withIntermediateDirectories: true)

        let found = LocalProviderDiscovery.scan(home: home.path, path: "", applicationRoots: []).filter { $0.app == .claudeCode }
        XCTAssertEqual(found.map(\.name), ["Claude Code · org"])
        XCTAssertEqual(found.first?.profilePath, org.path)

        let account = Account(id: "a", name: "org", app: .claudeCode, profilePath: org.path, sessionRoot: org.path,
                              createdAt: Date(), lastLaunchedAt: nil, localProvider: found.first?.configuration)
        let script = try LocalProviderLauncher.script(for: account, directory: home)
        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR=" + LocalProviderLauncher.quote(org.path)))
        // A Console login lives in the Anthropic profile directory, not in CLAUDE_CONFIG_DIR. Each account gets its own,
        // so the default ~/.claude never falls back to this organization's sign-in.
        XCTAssertTrue(script.contains("export ANTHROPIC_CONFIG_DIR=" + LocalProviderLauncher.quote(org.appendingPathComponent("anthropic").path)))
    }

    func testStoreSavesCreditOnlyForClaudeCode() throws {
        let home = try makeTempDir()
        let store = AccountStore(root: home.appendingPathComponent("Perch"), agentDeskProfiles: home.appendingPathComponent("none"), home: home.path)
        try store.load()
        let org = home.appendingPathComponent("org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let account = try store.importLocal(.init(name: "org", app: .claudeCode, profilePath: org.path,
                                                  configuration: .init(kind: .terminal, target: "/bin/sh")))
        XCTAssertNil(account.creditGrants)
        let grants = [CreditGrant(amount: 157.94, grantedOn: "2026-11-06", expiresOn: "2026-12-09")]
        try store.setCredit(id: account.id, grants: grants)
        let reloaded = AccountStore(root: store.root, agentDeskProfiles: home.appendingPathComponent("none"), home: home.path)
        try reloaded.load()
        XCTAssertEqual(reloaded.accounts.first?.creditGrants, grants)
        XCTAssertThrowsError(try store.setCredit(id: account.id, grants: [.init(amount: 1, grantedOn: "2026-12-09", expiresOn: "2026-11-06")]))
        try store.setCredit(id: account.id, grants: [])
        XCTAssertNil(store.accounts.first?.creditGrants)
    }
}
