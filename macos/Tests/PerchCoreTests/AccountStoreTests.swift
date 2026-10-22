import XCTest
@testable import PerchCore

final class AccountStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func emptyStore() throws -> AccountStore {
        let store = AccountStore(root: root.appendingPathComponent("Perch"))
        try store.load()
        return store
    }

    func testFirstLoadStartsEmptyAndSaves() throws {
        let store = try emptyStore()
        XCTAssertEqual(store.accounts, [])
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testOlderFilesWithSkippedImportsStillLoad() throws {
        let dir = root.appendingPathComponent("Perch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = #"{"version":1,"skippedImports":["Cur（cursor）"],"accounts":[{"id":"a1","name":"Omnix","appId":"codex","profilePath":"/p/codex","sessionRoot":"/p/codex/codex-home","createdAt":"2026-09-15T04:12:56.102Z"}]}"#
        try file.write(to: dir.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        let store = AccountStore(root: dir)
        try store.load()
        XCTAssertEqual(store.accounts.map(\.name), ["Omnix"])
    }

    func testCreateRenameDeleteKeepsDataByDefault() throws {
        let store = try emptyStore()
        XCTAssertEqual(store.accounts, [])

        let account = try store.create(name: " Work/Alt ", app: .codex)
        XCTAssertEqual(account.name, "Work/Alt")
        XCTAssertTrue(account.profilePath.contains("/Profiles/Codex/Work-Alt-"), account.profilePath)
        XCTAssertEqual(account.sessionRoot, account.profilePath + "/codex-home")
        let perms = try FileManager.default.attributesOfItem(atPath: account.sessionRoot)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700)

        XCTAssertThrowsError(try store.rename(id: account.id, to: "  "))
        try store.rename(id: account.id, to: "Omnix 2")
        XCTAssertEqual(store.accounts.first?.name, "Omnix 2")

        try store.delete(id: account.id, moveDataToTrash: false)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: account.profilePath), "默认保留数据目录")

        let claude = try store.create(name: "Omnid", app: .claude)
        XCTAssertTrue(claude.profilePath.contains("/Profiles/Claude/Omnid-"))
        XCTAssertEqual(claude.sessionRoot, claude.profilePath)
        XCTAssertThrowsError(try store.create(name: "   ", app: .claude))
    }

    func testTrashIsRefusedWhileTheClientMayStillUseTheData() throws {
        var running: [RunningProcess]? = nil
        let store = AccountStore(root: root.appendingPathComponent("Perch"),
                                 processes: { running })
        try store.load()
        let account = try store.create(name: "Omnid", app: .claude)

        XCTAssertThrowsError(try store.delete(id: account.id, moveDataToTrash: true)) {
            XCTAssertEqual($0 as? AccountError, .runningUnknown, "ps 失败时不能当成没在运行")
        }
        XCTAssertEqual(store.accounts.map(\.id), [account.id])

        running = [RunningProcess(pid: 42, args: "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(account.profilePath)")]
        XCTAssertThrowsError(try store.delete(id: account.id, moveDataToTrash: true)) {
            XCTAssertEqual($0 as? AccountError, .dataInUse)
        }
        XCTAssertEqual(store.accounts.map(\.id), [account.id], "拒绝时保留账号")
        XCTAssertTrue(FileManager.default.fileExists(atPath: account.profilePath))

        // Only removing the slot never needs the process list.
        running = nil
        try store.delete(id: account.id, moveDataToTrash: false)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testMoveReordersAndPersists() throws {
        let store = try emptyStore()
        let a = try store.create(name: "A", app: .codex), b = try store.create(name: "B", app: .codex)
        let c = try store.create(name: "C", app: .claude)
        try store.move(id: c.id, before: a.id)
        XCTAssertEqual(store.accounts.map(\.name), ["C", "A", "B"])
        try store.move(id: c.id, before: nil)
        XCTAssertEqual(store.accounts.map(\.name), ["A", "B", "C"])
        try store.move(id: b.id, before: a.id)
        let reopened = AccountStore(root: store.root)
        try reopened.load()
        XCTAssertEqual(reopened.accounts.map(\.name), ["B", "A", "C"])
        XCTAssertThrowsError(try store.move(id: a.id, before: "missing"))
        XCTAssertEqual(store.accounts.map(\.name), ["B", "A", "C"], "目标不存在时顺序不变")
    }

    func testRelocateAndMarkLaunchedPersist() throws {
        let store = try emptyStore()
        let account = try store.create(name: "X", app: .codex)
        try store.relocate(id: account.id, profilePath: "/new/place")
        let other = try store.create(name: "Z", app: .claude)
        XCTAssertThrowsError(try store.relocate(id: other.id, profilePath: "/new/place")) {
            XCTAssertEqual($0 as? AccountError, .alreadyAdded, "不能把账号定位到另一个账号的目录")
        }
        XCTAssertEqual(store.accounts.first { $0.id == other.id }?.profilePath, other.profilePath)
        try store.delete(id: other.id, moveDataToTrash: false)
        let launched = Date(timeIntervalSince1970: 1_800_000_000)
        try store.markLaunched(id: account.id, at: launched)
        XCTAssertThrowsError(try store.rename(id: "nope", to: "Y"))

        let reopened = AccountStore(root: store.root)
        try reopened.load()
        XCTAssertEqual(reopened.accounts.first?.profilePath, "/new/place")
        XCTAssertEqual(reopened.accounts.first?.sessionRoot, "/new/place/codex-home")
        XCTAssertEqual(reopened.accounts.first?.lastLaunchedAt, launched)
    }

    func testFailedLoadBlocksWritesSoSlotsAreNotWiped() throws {
        let dir = root.appendingPathComponent("Perch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ invalid json".write(to: dir.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        let store = AccountStore(root: dir)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.create(name: "新账号", app: .codex)) { XCTAssertEqual($0 as? AccountError, .notLoaded) }
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "{ invalid json", "读取失败时不覆盖原文件")
        XCTAssertEqual(AccountError.notLoaded.errorDescription, "账号列表尚未成功读取，已停止写入以免覆盖")
    }

    func testRemovedProviderAccountsMoveToBackupOnce() throws {
        let first = AccountStore(root: root)
        try first.load()
        let codex = try first.create(name: "Codex", app: .codex)
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first.fileURL)) as? [String: Any])
        var rows = try XCTUnwrap(file["accounts"] as? [[String: Any]])
        rows += [
            ["id": "api", "name": "API", "appId": "api", "profilePath": "", "sessionRoot": "", "createdAt": "2026-01-01T00:00:00Z",
             "apiProvider": ["displayName": "Fixture", "baseURL": "https://example.com/v1"]],
            ["id": "custom", "name": "Custom", "appId": "custom", "profilePath": "", "sessionRoot": "", "createdAt": "2026-01-01T00:00:00Z",
             "localProvider": ["kind": "terminal", "target": "/usr/bin/true"]],
            ["id": "site", "name": "Site", "appId": "gemini", "profilePath": "", "sessionRoot": "", "createdAt": "2026-01-01T00:00:00Z",
             "localProvider": ["kind": "website", "target": "https://example.com"]]
        ]
        file["accounts"] = rows
        try JSONSerialization.data(withJSONObject: file).write(to: first.fileURL)

        let store = AccountStore(root: root)
        try store.load()
        XCTAssertEqual(store.accounts.map(\.id), [codex.id])
        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.removedAccountsURL)) as? [String: Any])
        let removed = try XCTUnwrap(backup["accounts"] as? [[String: Any]])
        XCTAssertEqual(removed.compactMap { $0["id"] as? String }, ["api", "custom", "site"])
        XCTAssertEqual((removed[0]["apiProvider"] as? [String: Any])?["baseURL"] as? String, "https://example.com/v1")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.removedAccountsURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let saved = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("apiProvider"))
        XCTAssertFalse(saved.contains("website"))

        let again = AccountStore(root: root)
        try again.load()
        XCTAssertEqual(again.accounts.map(\.id), [codex.id])
        let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: again.removedAccountsURL)) as? [String: Any])
        XCTAssertEqual((unchanged["accounts"] as? [[String: Any]])?.count, 3)
    }
}
