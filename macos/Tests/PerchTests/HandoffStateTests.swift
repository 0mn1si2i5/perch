import XCTest
import PerchCore
@testable import Perch

final class HandoffStateTests: XCTestCase {
    func testRestartRestoresPendingAndCancelPreservesGeneratedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("missing"))
        let handoffs = HandoffStore(root: root)
        let pending = try handoffs.prepare(sourceID: "s", targetID: "t", conversationID: "c", title: "任务")
        let file = handoffs.preparedURL(for: pending)
        try "交接文档".write(to: file, atomically: true, encoding: .utf8)
        let model = PerchModel(store: store)
        XCTAssertEqual(model.pendingHandoff, pending)
        model.cancelHandoffPreparation()
        XCTAssertNil(model.pendingHandoff)
        XCTAssertNil(try handoffs.pendingPreparation())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnreadablePendingIsPreservedAndDoesNotBlockNewHandoffs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("missing"))
        let handoffs = HandoffStore(root: root)
        _ = try handoffs.prepare(sourceID: "s", targetID: "t", conversationID: "c", title: "任务")
        try Data("bad state".utf8).write(to: handoffs.directory.appendingPathComponent("pending.json"))
        let model = PerchModel(store: store)
        XCTAssertNil(model.pendingHandoff)
        XCTAssertTrue(model.message?.contains("已保留备份") == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: handoffs.directory.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("pending-unreadable-") }.count, 1)
        XCTAssertNoThrow(try handoffs.prepare(sourceID: "s", targetID: "t", conversationID: "c", title: "重新准备"))
    }

    /// Right-click → 拆出需求到… → 本账号新对话, then 继续接力, with a stub client and a private clipboard.
    func testSplitIntoANewConversationOfTheSameAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("missing"))
        try store.load()
        let account = try store.create(name: "Omnix", app: .codex)
        let launcher = Launcher(activate: { _ in true }, processes: {
            [RunningProcess(pid: 42, args: "/Applications/Codex.app/Contents/MacOS/Codex --user-data-dir=\(account.profilePath)")]
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("perch-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var notices: [String] = []
        let model = PerchModel(store: store, launcher: launcher, pasteboard: pasteboard,
                               notificationSender: { notice, reply in notices.append(notice.body); reply(true) })
        let row = SessionRow(kind: .codex(CodexTask(id: UUID().uuidString, title: "原任务", status: .completed,
                                                    turnID: "t", updatedAt: Date(), source: "vscode")))

        model.handoff(row, from: account, to: account, scope: .split)
        let pending = try XCTUnwrap(model.pendingHandoff)
        XCTAssertTrue(pending.staysInAccount)
        XCTAssertEqual(pending.scope, .split)
        let draft = model.handoffs.preparedURL(for: pending)
        XCTAssertEqual(pasteboard.string(forType: .string), HandoffDocument.preparationPrompt(savedAt: draft, scope: .split))

        try "# 拆出的需求\n下一步：在新分支实现。".write(to: draft, atomically: true, encoding: .utf8)
        model.continueHandoff()
        let delivered = expectation(for: NSPredicate { _, _ in model.pendingHandoff == nil && !model.completingHandoff },
                                    evaluatedWith: nil)
        wait(for: [delivered], timeout: 5)

        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.hasPrefix(HandoffDocument.splitClipboardPreamble))
        XCTAssertTrue(copied.hasSuffix("下一步：在新分支实现。"))
        let entry = try XCTUnwrap(model.handoffLog.first)
        XCTAssertTrue(entry.staysInAccount)
        XCTAssertTrue(entry.isSplit)
        XCTAssertEqual(entry.result, "文档已准备，待粘贴发送")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(entry.documentPath)))
        XCTAssertEqual(PerchModel.handoffRoute(source: entry.source, target: entry.target, sameAccount: entry.staysInAccount),
                       "Omnix · 新对话")
        XCTAssertTrue(notices.contains { $0.contains("Omnix 新建另一个对话") }, notices.joined(separator: "\n"))
    }

    /// A model whose launcher cannot start anything, created before handoffs/ exists, as on a fresh install.
    private func failingTargetModel(_ root: URL) throws -> (PerchModel, Account, Account, NSPasteboard) {
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("missing"))
        try store.load()
        let source = try store.create(name: "Source", app: .codex)
        let target = try store.create(name: "Target", app: .claude)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("perch-test-\(UUID().uuidString)"))
        // No process list: the launcher refuses to start the target.
        let model = PerchModel(store: store, launcher: Launcher(activate: { _ in false }, processes: { nil }),
                               pasteboard: pasteboard, notificationSender: { _, reply in reply(true) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.handoffs.directory.path))
        return (model, source, target, pasteboard)
    }

    private func attempt(_ model: PerchModel) {
        model.continueHandoff()
        let finished = expectation(for: NSPredicate { _, _ in !model.completingHandoff && model.handoffLog.count == 1 },
                                   evaluatedWith: nil)
        wait(for: [finished], timeout: 5)
        XCTAssertNotNil(model.pendingHandoff)
    }

    private func copies(_ model: PerchModel) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: model.handoffs.directory.path).filter { $0.hasSuffix(".md") }
    }

    /// The target fails to open; retrying twice must not save another copy or add another log line.
    func testRetryAfterTargetLaunchFailureReusesCopyAndRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, source, target, pasteboard) = try failingTargetModel(root)
        defer { pasteboard.releaseGlobally() }
        let row = SessionRow(kind: .codex(CodexTask(id: UUID().uuidString, title: "重试任务", status: .completed,
                                                    turnID: "t", updatedAt: Date(), source: "vscode")))
        model.handoff(row, from: source, to: target)
        let pending = try XCTUnwrap(model.pendingHandoff)
        try "# 交接\n下一步：继续。".write(to: model.handoffs.preparedURL(for: pending), atomically: true, encoding: .utf8)

        for _ in 1...3 { attempt(model) }
        XCTAssertEqual(try copies(model).count, 1)
        XCTAssertEqual(model.handoffs.recentLog(limit: .max).count, 1)
        let entry = try XCTUnwrap(model.handoffLog.first)
        XCTAssertEqual(entry.result, "文档已准备，目标启动失败")
        XCTAssertEqual(entry.documentPath, model.pendingHandoff?.documentPath)
        XCTAssertEqual(entry.recordID, model.pendingHandoff?.recordID)
        XCTAssertEqual(try model.handoffs.pendingPreparation()?.documentPath, entry.documentPath)
    }

    /// After a failed attempt the agent rewrites the draft; the retry must paste the new text, not the old copy.
    func testRetryCopiesTheDraftAgainWhenItWasRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, source, target, pasteboard) = try failingTargetModel(root)
        defer { pasteboard.releaseGlobally() }
        let row = SessionRow(kind: .codex(CodexTask(id: UUID().uuidString, title: "改写任务", status: .completed,
                                                    turnID: "t", updatedAt: Date(), source: "vscode")))
        model.handoff(row, from: source, to: target)
        let draft = model.handoffs.preparedURL(for: try XCTUnwrap(model.pendingHandoff))
        try "# 旧版\n旧的下一步。".write(to: draft, atomically: true, encoding: .utf8)
        attempt(model)
        let first = try XCTUnwrap(model.pendingHandoff?.documentPath)

        // Age the first copy so the rewritten draft is clearly newer, then copy the prompt again for the same handoff.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: first)
        model.handoff(row, from: source, to: target)
        try "# 新版\n新的下一步。".write(to: draft, atomically: true, encoding: .utf8)
        attempt(model)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("新的下一步。") == true)
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("旧的下一步。") == true)
        XCTAssertNotEqual(model.pendingHandoff?.documentPath, first)
        XCTAssertEqual(try copies(model).count, 2)
        XCTAssertEqual(model.handoffs.recentLog(limit: .max).count, 1, "the same handoff keeps one record")

        attempt(model)
        XCTAssertEqual(try copies(model).count, 2, "an unchanged draft reuses the newest copy")
    }
}
