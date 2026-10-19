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
        XCTAssertEqual(sessions.count, 5)
        XCTAssertEqual(sessions.last?.id, "malformed", "a row without a usable time is listed last, without a date")
        XCTAssertNil(sessions.last?.updatedAt)
        XCTAssertEqual(sessions.last?.status, .unknown)
        XCTAssertEqual(sessions.first { $0.id == "active" }?.status, .running)
        XCTAssertEqual(sessions.first { $0.id == "idle" }?.status, .unknown)
        XCTAssertEqual(sessions.first { $0.id == "stale" }?.status, .interrupted)
        XCTAssertEqual(sessions.first { $0.id == "active" }?.path, dbPath.path)
        XCTAssertEqual(try Data(contentsOf: dbPath), before)
    }

    func testDeepSeekSkipsBrokenAndBlankMetadataAndCapsRecent() throws {
        let root = try fixture(), folder = root.appendingPathComponent("storages/session_projcache/sessions")
        for i in 0..<35 {
            let record: [String: Any] = ["identity": ["createdAt": 1_700_000_000_000],
                "rows": ["title": ["val": "Fixture \(i)"],
                         "sessionListMetadata": ["val": ["blank": false, "lastPromptAt": 1_700_000_000_000 + i * 1000]]]]
            try write(["version": 1, "record": record], folder.appendingPathComponent("session-\(i).json"))
        }
        try write(["record": ["identity": [:], "rows": ["sessionListMetadata": ["val": ["blank": true]]]]], folder.appendingPathComponent("blank.json"))
        try Data("invalid".utf8).write(to: folder.appendingPathComponent("broken.json"))
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
        for app in [AppKind.antigravity, .gemini, .deepseek, .codex] {
            XCTAssertTrue(LocalProviderSessions.recent(account(app, root)).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversation_summaries.db").path))
    }

    func testUnchangedFilesAreNotParsedAgain() throws {
        let root = try fixture(), folder = root.appendingPathComponent("tmp/project/chats")
        for i in 0..<3 {
            try write(["sessionId": "s\(i)", "lastUpdated": "2026-01-0\(i + 1)T00:00:00Z", "title": "Fixture \(i)"],
                      folder.appendingPathComponent("session-\(i).json"))
        }
        let reader = LocalProviderSessionReader(account: account(.gemini, root))
        XCTAssertEqual(reader.recent().count, 3)
        XCTAssertEqual(reader.parsed, 3)
        XCTAssertEqual(reader.recent().count, 3)
        XCTAssertEqual(reader.parsed, 3, "unchanged files must come from the cache")
        try write(["sessionId": "s0", "lastUpdated": "2026-02-01T00:00:00Z", "title": "Renamed fixture"],
                  folder.appendingPathComponent("session-0.json"))
        let sessions = reader.recent()
        XCTAssertEqual(reader.parsed, 4)
        XCTAssertEqual(sessions.first?.title, "Renamed fixture")
    }

    func testOnlyTheNewestFilesAreParsed() throws {
        let root = try fixture(), folder = root.appendingPathComponent("storages/session_projcache/sessions")
        let base = Date().addingTimeInterval(-10_000)
        for i in 0..<(LocalProviderSessionReader.fileLimit + 20) {
            let file = folder.appendingPathComponent("session-\(i).json")
            try write(["record": ["identity": [:], "rows": ["title": ["val": "Fixture \(i)"]]]], file)
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(i))], ofItemAtPath: file.path)
        }
        let reader = LocalProviderSessionReader(account: account(.deepseek, root))
        let sessions = reader.recent()
        XCTAssertEqual(reader.parsed, LocalProviderSessionReader.fileLimit)
        XCTAssertEqual(sessions.first?.id, "session-\(LocalProviderSessionReader.fileLimit + 19)")
    }

    func testLongSessionsStillAppearWithHeaderTitles() throws {
        let root = try fixture(), chats = root.appendingPathComponent("tmp/project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let filler = String(repeating: "x", count: 1024)
        let messages = (0..<2500).map { _ in #"{"type":"user","content":"\#(filler)","title":"Not a title"}"# }.joined(separator: ",")
        try Data(#"{"sessionId":"long-json","lastUpdated":"2026-03-01T00:00:00Z","title":"Long fixture","messages":[\#(messages)]}"#.utf8)
            .write(to: chats.appendingPathComponent("session-long.json"))
        var lines = [#"{"sessionId":"long-jsonl","projectHash":"p","startTime":"2026-03-02T00:00:00Z","lastUpdated":"2026-03-02T00:00:00Z","kind":"main"}"#]
        lines += (0..<2500).map { _ in #"{"id":"m","type":"user","content":[{"text":"\#(filler)"}]}"# }
        try Data(lines.joined(separator: "\n").utf8).write(to: chats.appendingPathComponent("session-long.jsonl"))
        let sessions = LocalProviderSessions.recent(account(.gemini, root))
        XCTAssertEqual(Set(sessions.map(\.id)), ["long-json", "long-jsonl"])
        XCTAssertEqual(sessions.first { $0.id == "long-json" }?.title, "Long fixture")
        XCTAssertEqual(sessions.first { $0.id == "long-jsonl" }?.title, "未命名会话")

        let folder = root.appendingPathComponent("storages/session_projcache/sessions")
        let body = String(repeating: "y", count: 3 * 1024 * 1024)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":1,"record":{"identity":{"createdAt":1},"rows":{"title":{"ver":1,"seq":2,"val":"Large \"fixture\""},"state":{"val":"\#(body)"}}}}"#.utf8)
            .write(to: folder.appendingPathComponent("large.json"))
        let large = LocalProviderSessions.recent(account(.deepseek, root))
        XCTAssertEqual(large.map(\.id), ["large"])
        XCTAssertEqual(large.first?.title, "Large \"fixture\"")
    }

    func testAntigravityZeroTimeCountsAsNoDate() throws {
        let root = try fixture(), dbPath = root.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT, last_modified_time TEXT, status TEXT);
            INSERT INTO conversation_summaries VALUES ('dated','Dated fixture','2026-01-01T00:00:00Z','CASCADE_RUN_STATUS_IDLE');
            INSERT INTO conversation_summaries VALUES ('zero','Zero fixture','0001-01-01T00:00:00Z','CASCADE_RUN_STATUS_RUNNING');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let sessions = LocalProviderSessions.recent(account(.antigravity, root))
        XCTAssertEqual(sessions.map(\.id), ["dated", "zero"])
        XCTAssertNil(sessions.last?.updatedAt)
        XCTAssertEqual(sessions.last?.status, .unknown)
    }

    /// A WAL database whose writer has closed has no -wal file; a plain read-only open fails on it.
    func testAntigravityWALDatabaseWithoutWALFileIsRead() throws {
        let root = try fixture(), dbPath = root.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT, last_modified_time TEXT, status TEXT);
            INSERT INTO conversation_summaries VALUES ('wal','WAL fixture','2026-01-01T00:00:00Z','CASCADE_RUN_STATUS_IDLE');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        // macOS keeps an empty -wal file after the last connection closes; other writers delete it.
        try? FileManager.default.removeItem(atPath: dbPath.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath.path + "-shm")
        XCTAssertTrue(ReadOnlyDatabase.isWAL(dbPath.path))
        let reader = LocalProviderSessionReader(account: account(.antigravity, root))
        XCTAssertEqual(reader.recent().map(\.id), ["wal"])
        XCTAssertEqual(reader.recent().map(\.id), ["wal"])
        XCTAssertEqual(reader.parsed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath.path + "-shm"))
    }
}
