import XCTest
@testable import PerchCore

final class MootAccountBindingTests: XCTestCase {
    private func claudeCode(id: String, name: String, directory: String, executable: String?) -> Account {
        Account(id: id, name: name, app: .claudeCode, profilePath: directory, sessionRoot: directory,
                createdAt: Date(timeIntervalSince1970: 0), lastLaunchedAt: nil,
                localProvider: executable.map { .init(kind: .terminal, target: $0, workingDirectory: "/Users/me") })
    }

    /// Perch estimates what these directories spend against Console organization credit, so they are offered as console connections.
    func testClaudeCodeAccountBecomesConsoleConnection() throws {
        let account = claudeCode(id: "320bd3c9", name: "Claude Code · org", directory: "/Users/me/.perch/claude/org",
                                 executable: "/opt/claude-test/bin/claude")
        let found = MootAccountBinding.candidates(accounts: [account], existing: []).map(\.connection)
        XCTAssertEqual(found.count, 1)
        let connection = try XCTUnwrap(found.first)
        XCTAssertEqual(connection.name, "Claude Code · org")
        XCTAssertEqual(connection.adapter, "claude")
        XCTAssertEqual(connection.authMode, "console")
        XCTAssertEqual(connection.accountRoot, "/Users/me/.perch/claude/org")
        XCTAssertEqual(connection.executable, "/opt/claude-test/bin/claude")
        XCTAssertEqual(connection.perchAccountID, "320bd3c9")
        XCTAssertEqual(connection.tools, [])
    }

    func testSkipsAccountsAlreadyBoundToAConnection() {
        let bound = claudeCode(id: "a", name: "Claude Code · org", directory: "/Users/me/.perch/claude/org",
                               executable: "/opt/claude-test/bin/claude")
        let unbound = claudeCode(id: "b", name: "Claude Code · team", directory: "/Users/me/.perch/claude/team",
                                 executable: "/opt/claude-test/bin/claude")
        var existing = MootConnection(); existing.id = "claude-org"; existing.perchAccountID = "a"
        let found = MootAccountBinding.candidates(accounts: [bound, unbound], existing: [existing])
        XCTAssertEqual(found.map(\.connection.perchAccountID), ["b"])
    }

    /// Moot refuses to save a configuration whose executable is not an absolute path.
    func testSkipsClaudeCodeAccountWithoutLaunchCommand() {
        let account = claudeCode(id: "a", name: "Claude Code · org", directory: "/Users/me/.perch/claude/org", executable: nil)
        XCTAssertTrue(MootAccountBinding.candidates(accounts: [account], existing: []).isEmpty)
    }
}
