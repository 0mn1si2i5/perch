import XCTest
import SQLite3
@testable import PerchCore

final class LocalProviderSessionsTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func account(_ app: AppKind, _ root: URL) -> Account {
        .init(id: "fixture", name: "Fixture", app: app, profilePath: root.path,
              sessionRoot: root.path, createdAt: Date(), lastLaunchedAt: nil)
    }

    private func write(_ value: Any, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }

    func testAntigravityUsesMetadataAndDoesNotClaimIdleCompleted() throws {
        let root = try fixture(), dbPath = root.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &db), SQLITE_OK)
        let now = ISO8601.string(Date())
        let stale = ISO8601.string(Date().addingTimeInterval(-3600))
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT, last_modified_time TEXT, status TEXT);
            INSERT INTO conversation_summaries VALUES ('active','Active fixture','\(now)','CASCADE_RUN_STATUS_RUNNING');
            INSERT INTO conversation_summaries VALUES ('idle','Idle fixture','\(now)','CASCADE_RUN_STATUS_IDLE');
            INSERT INTO conversation_summaries VALUES ('stale','Stale fixture','\(stale)','CASCADE_RUN_STATUS_RUNNING');
            INSERT INTO conversation_summaries VALUES ('malformed','Invalid date','bad','CASCADE_RUN_STATUS_RUNNING');
            INSERT INTO conversation_summaries VALUES ('sql-date','SQL timestamp','2026-01-01 12:53:41.86159+00:00','CASCADE_RUN_STATUS_IDLE');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: dbPath)
        let sessions = LocalProviderSessions.recent(account(.antigravity, root))
        XCTAssertEqual(sessions.count, 4)
        XCTAssertEqual(sessions.first { $0.id == "active" }?.status, .running)
        XCTAssertEqual(sessions.first { $0.id == "idle" }?.status, .unknown)
        XCTAssertEqual(sessions.first { $0.id == "stale" }?.status, .interrupted)
        XCTAssertEqual(sessions.first { $0.id == "active" }?.path, dbPath.path)
        XCTAssertEqual(try Data(contentsOf: dbPath), before)
    }

    func testDeepSeekSkipsBrokenBlankAndOversizedMetadataAndCapsRecent() throws {
        let root = try fixture(), folder = root.appendingPathComponent("storages/session_projcache/sessions")
        for i in 0..<35 {
            let record: [String: Any] = ["identity": ["createdAt": 1_700_000_000_000],
                "rows": ["title": ["val": "Fixture \(i)"],
                         "sessionListMetadata": ["val": ["blank": false, "lastPromptAt": 1_700_000_000_000 + i * 1000]]]]
            try write(["version": 1, "record": record], folder.appendingPathComponent("session-\(i).json"))
        }
        try write(["record": ["identity": [:], "rows": ["sessionListMetadata": ["val": ["blank": true]]]]], folder.appendingPathComponent("blank.json"))
        try Data("invalid".utf8).write(to: folder.appendingPathComponent("broken.json"))
        try Data(repeating: 32, count: 2 * 1024 * 1024 + 1).write(to: folder.appendingPathComponent("large.json"))
        let sessions = LocalProviderSessions.recent(account(.deepseek, root))
        XCTAssertEqual(sessions.count, 30)
        XCTAssertEqual(sessions.first?.id, "session-34")
        XCTAssertEqual(sessions.last?.id, "session-5")
        XCTAssertTrue(sessions.allSatisfy { $0.status == .unknown })
    }

    func testGeminiReadsHeaderWithoutUsingMessageAsTitleAndSkipsSymlinks() throws {
        let root = try fixture(), external = try fixture()
        try write(["sessionId": "header", "lastUpdated": "2026-01-01T00:00:00Z", "title": "Fixture heading"],
                  root.appendingPathComponent("tmp/project/chats/session-header.json"))
        try write(["sessionId": "untitled", "lastUpdated": "2026-01-02T00:00:00Z", "messages": [["content": "Do not use body as title"]]],
                  root.appendingPathComponent("tmp/project/chats/session-untitled.json"))
        try write(["sessionId": "external", "title": "Outside"], external.appendingPathComponent("chats/session-outside.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("tmp/external"), withDestinationURL: external)
        let sessions = LocalProviderSessions.recent(account(.gemini, root))
        XCTAssertEqual(sessions.map(\.id), ["untitled", "header"])
        XCTAssertEqual(sessions.first?.title, "未命名会话")
        XCTAssertEqual(sessions.last?.title, "Fixture heading")
    }

    func testMissingSourcesRemainAbsent() throws {
        let root = try fixture()
        for app in [AppKind.antigravity, .gemini, .deepseek, .codex, .api] {
            XCTAssertTrue(LocalProviderSessions.recent(account(app, root)).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversation_summaries.db").path))
    }
}
