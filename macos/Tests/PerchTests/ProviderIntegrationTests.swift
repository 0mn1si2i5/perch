import AppKit
import SwiftUI
import XCTest
import PerchCore
@testable import Perch

final class ProviderIntegrationTests: XCTestCase {
    func testProviderEditingPersistsAlongsideDesktopAccountsWithoutInventingQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-provider-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        try store.load()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let codex = try store.create(name: "Existing Codex", app: .codex, now: now)
        let claude = try store.create(name: "Existing Claude", app: .claude, now: now)
        let model = makeModel(store)

        let website = LocalProviderConfiguration(kind: .website, target: "https://example.com/chat")
        XCTAssertTrue(model.saveLocalProvider(existing: nil, name: "  Web entry  ", profilePath: "", configuration: website))
        let local = try XCTUnwrap(model.accounts.first { $0.app == .custom })
        XCTAssertEqual(local.name, "Web entry")
        XCTAssertFalse(model.dataMissing(local))
        XCTAssertTrue(model.rows(for: local).isEmpty)
        model.refreshQuota(local)
        XCTAssertNil(model.quotas[local.id])
        XCTAssertFalse(model.refreshingQuotas.contains(local.id))

        let configuration = APIProviderConfiguration(displayName: "Local API", baseURL: "http://127.0.0.1:11434/v1", model: "example-model")
        // New credentials-free metadata, then a same-endpoint edit: neither path reads or writes Keychain.
        XCTAssertTrue(model.saveAPIProvider(existing: nil, name: "Local API", configuration: configuration, key: nil, removeKey: false))
        let api = try XCTUnwrap(model.accounts.first { $0.app == .api })
        XCTAssertFalse(model.dataMissing(api))
        XCTAssertTrue(model.rows(for: api).isEmpty)
        model.refreshQuota(api)
        XCTAssertNil(model.quotas[api.id])
        XCTAssertFalse(model.refreshingQuotas.contains(api.id))
        model.apiModels[api.id] = ["example-model", "another-model"]
        model.apiChecks[api.id] = "Synthetic prior check"
        var edited = configuration
        edited.model = "another-model"
        XCTAssertTrue(model.saveAPIProvider(existing: api, name: "Renamed API", configuration: edited, key: nil, removeKey: false))
        XCTAssertNil(model.apiModels[api.id], "Saving changed metadata invalidates the prior connection result")
        XCTAssertNil(model.apiChecks[api.id])

        let persistedBeforeFailure = try Data(contentsOf: store.fileURL)
        let invalidWebsite = LocalProviderConfiguration(kind: .website, target: "file:///tmp/provider-test")
        XCTAssertFalse(model.saveLocalProvider(existing: local, name: "Invalid change", profilePath: "", configuration: invalidWebsite))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), persistedBeforeFailure)

        let reloaded = makeStore(root)
        try reloaded.load()
        XCTAssertEqual(reloaded.accounts.count, 4)
        XCTAssertEqual(reloaded.accounts.first { $0.id == codex.id }, codex)
        XCTAssertEqual(reloaded.accounts.first { $0.id == claude.id }, claude)
        XCTAssertEqual(reloaded.accounts.first { $0.id == local.id }?.localProvider, website)
        XCTAssertEqual(reloaded.accounts.first { $0.id == api.id }?.apiProvider, edited)
        XCTAssertEqual(reloaded.accounts.first { $0.id == api.id }?.name, "Renamed API")
        XCTAssertTrue(codex.app.hasQuota)
        XCTAssertTrue(claude.app.hasQuota)
        XCTAssertFalse(local.app.hasQuota)
        XCTAssertFalse(api.app.hasQuota)
        XCTAssertEqual(model.accounts.first { $0.id == codex.id }, codex)
        XCTAssertEqual(model.accounts.first { $0.id == claude.id }, claude)
    }

    @MainActor
    func testOptionalSyntheticProviderPreviews() async throws {
        guard let output = ProcessInfo.processInfo.environment["PERCH_PROVIDER_PREVIEW_DIR"] else {
            throw XCTSkip("Set PERCH_PROVIDER_PREVIEW_DIR to export synthetic provider UI previews")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-provider-preview-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        try store.load()
        let local = try store.saveProvider(Account(id: "preview-local", name: "示例本机 CLI", app: .custom,
                                                   profilePath: "", sessionRoot: "", createdAt: Date(), lastLaunchedAt: nil,
                                                   localProvider: .init(kind: .terminal, target: "/usr/bin/true", arguments: ["--example"], workingDirectory: root.path)))
        let api = try store.saveProvider(Account(id: "preview-api", name: "示例 API 账号", app: .api,
                                                 profilePath: "", sessionRoot: "", createdAt: Date(), lastLaunchedAt: nil,
                                                 apiProvider: .init(displayName: "示例供应商", baseURL: "https://api.example.com/v1", model: "example-model")))
        let model = makeModel(store)
        model.apiModels[api.id] = ["example-model", "example-model-large"]
        model.apiChecks[api.id] = "示例状态：已获取 2 个模型；尚未验证推理或额度"
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        try render(APIProviderEditorView(perch: model, account: api) {}, to: directory.appendingPathComponent("api-editor.png"))
        try render(LocalProviderEditorView(perch: model, account: local) {}, to: directory.appendingPathComponent("local-editor.png"))
        try render(NewAccountView(perch: model) {}, to: directory.appendingPathComponent("new-account.png"))
        let usageAccount = Account(id: "preview-usage", name: "示例 Antigravity", app: .antigravity,
                                   profilePath: "", sessionRoot: "", createdAt: Date(), lastLaunchedAt: nil,
                                   localProvider: .init(kind: .terminal, target: "/usr/bin/true"))
        model.providerUsage[usageAccount.id] = .init(metrics: [
            .init(label: "Gemini Models · 每周", remainingPercent: 96.8, resetsAt: Date(timeIntervalSince1970: 1_792_000_000)),
            .init(label: "Gemini Models · 5 小时", remainingPercent: 98.4, resetsAt: Date(timeIntervalSince1970: 1_792_000_000)),
            .init(label: "Claude and GPT models · 每周", remainingPercent: 100),
            .init(label: "Claude and GPT models · 5 小时", remainingPercent: 100)
        ], summary: "Antigravity 实时额度", authenticationVerified: true)
        try render(VStack(spacing: 10) {
            AccountCard(perch: model, account: usageAccount)
            ProviderUsageView(usage: .init(metrics: [
                .init(label: "充值余额", value: "CNY 20.12345678"),
                .init(label: "赠送余额", value: "CNY 1.25")
            ], summary: "DeepSeek 账户余额", authenticationVerified: true), error: nil, refreshing: false)
            ProviderUsageView(usage: nil, error: "Gemini CLI 个人账号服务已迁移至 Antigravity；请使用 Antigravity 查询额度和运行模型", refreshing: false)
        }, to: directory.appendingPathComponent("provider-usage.png"))
        try render(VStack(spacing: 8) {
            AccountCard(perch: model, account: api)
            AccountCard(perch: model, account: local)
        }, to: directory.appendingPathComponent("provider-cards.png"))
    }

    private func makeStore(_ root: URL) -> AccountStore {
        AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("absent-agent-desk.json"), home: root.path)
    }

    private func makeModel(_ store: AccountStore) -> PerchModel {
        PerchModel(store: store, launcher: Launcher(activate: { _ in false }, processes: { [] }),
                   notificationSender: { _, _, completion in completion(true) })
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        // 304 pt is the real 340 pt panel's inner content width. Export full content to inspect wrapping.
        let view = NSHostingView(rootView: content
            .frame(width: 304, alignment: .leading)
            .padding(18)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        let size = view.fittingSize
        XCTAssertEqual(size.width, 340, accuracy: 1)
        XCTAssertGreaterThan(size.height, 100)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.orderOut(nil)
    }
}
