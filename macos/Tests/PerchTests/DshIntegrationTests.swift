import AppKit
import XCTest
@testable import PerchCore
@testable import Perch

final class DshIntegrationTests: XCTestCase {
    private func fixture(_ body: (PerchModel, AccountStore, Account, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("absent"), home: root.path)
        try store.load()
        let account = try store.configureDsh(name: "dsh", home: "", configuration: .init(mode: .external))
        let model = PerchModel(store: store, launcher: Launcher(activate: { _ in false }, processes: { [] }, run: { _ in }),
                               notificationSender: { _, done in done(true) })
        try body(model, store, account, root)
    }

    private func session(_ status: TaskStatus, title: String = "Example task") -> DshSession {
        .init(id: "session", title: title, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), status: status)
    }

    func testWebSnapshotsSurviveFilePollingAndFeedExistingPetAndSessionRows() throws {
        try fixture { model, _, account, _ in
            var petTasks: [CodexTask] = []
            model.onTasks = { tasks, _ in petTasks = tasks }
            model.applyDsh(.init(sessions: [session(.running)], running: true), for: account)
            XCTAssertTrue(model.runningIDs.contains(account.id))
            XCTAssertEqual(model.rows(for: account).first?.status, .running)
            XCTAssertNil(model.rows(for: account).first?.path)
            XCTAssertEqual(petTasks.first?.source, "DeepSeek Harness")
            model.apply(snapshots: [:], running: [], sessions: [:], readAccounts: model.accounts)
            XCTAssertTrue(model.runningIDs.contains(account.id), "file polling must not erase Web process state")
            XCTAssertEqual(petTasks.count, 1)
            let offline = DshSnapshot(sessions: [session(.unknown)], cached: true, detail: "Disconnected")
            model.applyDsh(offline, for: account)
            XCTAssertFalse(model.runningIDs.contains(account.id))
            XCTAssertTrue(petTasks.isEmpty, "cached Web tasks cannot keep the pet working forever")
            XCTAssertEqual(model.rows(for: account).count, 1, "keep visible cached metadata")
        }
    }

    func testCompletionRequiresObservedLiveTransitionAndStaleConfigurationIsIgnored() throws {
        try fixture { model, store, account, _ in
            var completions: [CodexTask] = []
            model.onTasks = { _, completed in if let completed { completions.append(completed) } }
            model.applyDsh(.init(sessions: [session(.completed)], running: true), for: account)
            XCTAssertTrue(completions.isEmpty)
            model.applyDsh(.init(sessions: [session(.running)], running: true), for: account)
            model.applyDsh(.init(sessions: [session(.completed)], cached: true), for: account)
            XCTAssertTrue(completions.isEmpty)
            model.applyDsh(.init(sessions: [session(.completed)], running: true), for: account)
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(completions.first?.title, "Example task")
            var changed = account.dshWeb!
            changed.balanceHome = store.root.path
            _ = try store.configureDsh(name: account.name, home: account.profilePath, configuration: changed, accountID: account.id)
            model.accounts = store.accounts
            model.resetDshState(account.id)
            model.applyDsh(.init(sessions: [session(.running, title: "Old response")], running: true), for: account)
            XCTAssertNil(model.dshSnapshots[account.id])
            XCTAssertFalse(model.runningIDs.contains(account.id))
        }
    }

    func testSourceEditorValidationKeepsSourceRootThroughStoreAndResolve() throws {
        try fixture { model, store, _, root in
            let source = root.appendingPathComponent("source")
            let cli = source.appendingPathComponent("apps/cli")
            let entry = cli.appendingPathComponent("lib/main.js")
            let web = source.appendingPathComponent("apps/web/dist/index.html")
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: web.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": "@deepseek-ai/dsh-root"]).write(to: source.appendingPathComponent("package.json"))
            try JSONSerialization.data(withJSONObject: ["name": "@deepseek-ai/dsh", "version": "1.0.0", "bin": ["dsh": "lib/main.js"]])
                .write(to: cli.appendingPathComponent("package.json"))
            try Data("fixture".utf8).write(to: entry)
            try Data("fixture".utf8).write(to: web)
            let node = root.appendingPathComponent("node")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
            let checked = try model.checkedDshConfiguration(.init(mode: .source, installationPath: source.path, nodePath: node.path), home: "")
            XCTAssertEqual(checked.mode, .source)
            XCTAssertEqual(checked.installationPath, source.resolvingSymlinksInPath().path)
            let saved = try store.configureDsh(name: "Source", home: "", configuration: checked)
            XCTAssertEqual(try DshInstallation.resolve(account: saved).workingDirectory, source.resolvingSymlinksInPath().path)
        }
    }

    func testWebAndExistingProviderUsageStaySeparate() throws {
        try fixture { model, store, account, root in
            XCTAssertTrue(model.supportsProviderUsage(account))
            XCTAssertFalse(model.dataMissing(account))
            XCTAssertNil(model.localWebURL(account))
            let agy = try store.importLocal(.init(name: "Antigravity", app: .antigravity, profilePath: root.path,
                                                  configuration: .init(kind: .terminal, target: "/usr/bin/true")))
            model.accounts = store.accounts
            model.refreshQuota(agy, manual: false)
            XCTAssertFalse(model.refreshingQuotas.contains(agy.id))
            XCTAssertEqual(Set(model.groups.map(\.app)), Set([.deepseek, .antigravity]))
        }
    }
}
