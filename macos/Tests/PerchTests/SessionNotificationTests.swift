import XCTest
@testable import PerchCore
@testable import Perch

/// Poll results are fed straight into the model; no client data is read.
final class SessionNotificationTests: XCTestCase {
    private var root: URL!
    private var notices: [PerchNotice] = []
    private var savedSetting: Any?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-notify-\(UUID().uuidString)")
        notices = []
        savedSetting = UserDefaults.standard.object(forKey: "notifySessionChanges")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.set(savedSetting, forKey: "notifySessionChanges")
    }

    /// `run` never starts a real client.
    private func makeModel(launcher: Launcher = Launcher(activate: { _ in false }, processes: { [] }, run: { _ in }),
                           pasteboard: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("perch-test-\(UUID().uuidString)")))
        throws -> (PerchModel, codex: Account, claude: Account) {
        let store = AccountStore(root: root, home: root.path)
        try store.load()
        let codex = try store.create(name: "Work", app: .codex)
        let claude = try store.create(name: "Personal", app: .claude)
        let model = PerchModel(store: store, launcher: launcher, pasteboard: pasteboard,
                               notificationSender: { [weak self] notice, reply in self?.notices.append(notice); reply(true) })
        model.notifySessionChanges = true
        return (model, codex, claude)
    }

    private func task(_ id: String, _ status: TaskStatus, title: String = "修复登录", exec: Bool = false) -> CodexTask {
        CodexTask(id: id, title: title, status: status, turnID: "turn", updatedAt: Date(), source: "test", isExec: exec)
    }

    /// A `.jsonl` path is Claude Code history; a `.json` one is a desktop conversation.
    private func session(_ id: String, _ status: TaskStatus, code: Bool = false) -> ClaudeSession {
        ClaudeSession(id: id, title: "写周报", cwd: nil, updatedAt: Date(), path: "/tmp/\(id)." + (code ? "jsonl" : "json"),
                      status: status)
    }

    private func poll(_ model: PerchModel, codex: Account, _ tasks: [CodexTask], available: Bool = true,
                      claude: Account? = nil, _ sessions: [ClaudeSession] = []) {
        var claudeSessions: [String: [ClaudeSession]] = [:]
        if let claude { claudeSessions[claude.id] = sessions }
        model.apply(snapshots: [codex.id: CodexSnapshot(tasks: tasks, available: available)], running: [],
                    sessions: claudeSessions, readAccounts: model.accounts)
    }

    func testCodexAndClaudeChangesNotifyAndClickOpensTheConversation() throws {
        let (model, codex, claude) = try makeModel()
        let taskID = UUID().uuidString
        poll(model, codex: codex, [task(taskID, .completed)], claude: claude, [session("old", .completed)])
        XCTAssertTrue(notices.isEmpty, "conversations finished before Perch started are not reported")

        poll(model, codex: codex, [task(taskID, .running)], claude: claude, [session("old", .completed)])
        poll(model, codex: codex, [task(taskID, .completed)], claude: claude, [session("old", .completed)])
        XCTAssertEqual(notices, [PerchNotice(title: "对话已完成", body: "Work：修复登录",
                                             action: .openSession(accountID: codex.id, sessionID: taskID))])

        poll(model, codex: codex, [task(taskID, .completed)], claude: claude, [session("c1", .running)])
        poll(model, codex: codex, [task(taskID, .completed)], claude: claude, [session("c1", .completed)])
        XCTAssertEqual(notices.last, PerchNotice(title: "对话已完成", body: "Personal：写周报",
                                                 action: .openSession(accountID: claude.id, sessionID: "c1")))
        XCTAssertEqual(notices.count, 2)

        XCTAssertTrue(model.perform(.openSession(accountID: claude.id, sessionID: "c1")))
        XCTAssertFalse(model.perform(.openSession(accountID: "gone", sessionID: "c1")), "an unknown account opens the panel")
    }

    func testSeveralChangesInOnePollShareOneNotification() throws {
        let (model, codex, claude) = try makeModel()
        poll(model, codex: codex, [task("a", .running), task("b", .running, title: "评审")], claude: claude, [session("c", .running)])
        poll(model, codex: codex, [task("a", .waiting), task("b", .failed, title: "评审")], claude: claude, [session("c", .completed)])
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].title, "3 个对话有新状态")
        XCTAssertNil(notices[0].action)
        XCTAssertEqual(notices[0].body, "Work：修复登录 · 等你回应\nWork：评审 · 遇到问题\nPersonal：写周报 · 已完成")
    }

    func testSwitchOffStopsNotificationsAndUnreadableDatabaseKeepsState() throws {
        let (model, codex, _) = try makeModel()
        poll(model, codex: codex, [task("a", .running)])
        model.notifySessionChanges = false
        poll(model, codex: codex, [task("a", .waiting)])
        XCTAssertTrue(notices.isEmpty)

        model.notifySessionChanges = true
        poll(model, codex: codex, [task("a", .running)])
        poll(model, codex: codex, [], available: false)
        poll(model, codex: codex, [task("a", .completed)])
        XCTAssertEqual(notices.map(\.title), ["对话已完成"])
    }

    func testExecRunsAndClaudeCodeHistoryAreNotNotified() throws {
        let (model, codex, claude) = try makeModel()
        poll(model, codex: codex, [task("exec", .running, exec: true)], claude: claude, [session("code", .running, code: true)])
        poll(model, codex: codex, [task("exec", .completed, exec: true)], claude: claude, [session("code", .completed, code: true)])
        XCTAssertTrue(notices.isEmpty, notices.map(\.body).joined(separator: "\n"))
    }
}
