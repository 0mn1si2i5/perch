import AppKit
import SwiftUI
import XCTest
import PerchCore
@testable import Perch

final class ProviderIntegrationTests: XCTestCase {
    func testImportedProvidersPersistAlongsideDesktopAccountsWithoutInventingQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-provider-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        try store.load()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let codex = try store.create(name: "Existing Codex", app: .codex, now: now)
        let claude = try store.create(name: "Existing Claude", app: .claude, now: now)
        let model = makeModel(store)

        let cliData = root.appendingPathComponent("gemini-home")
        try FileManager.default.createDirectory(at: cliData, withIntermediateDirectories: true)
        XCTAssertTrue(model.importLocal(LocalProviderCandidate(name: "Gemini CLI", app: .gemini, profilePath: cliData.path,
                                                               configuration: .init(kind: .terminal, target: "/usr/bin/true"))))
        let gemini = try XCTUnwrap(model.accounts.first { $0.app == .gemini })
        XCTAssertFalse(model.dataMissing(gemini))
        XCTAssertFalse(model.supportsProviderUsage(gemini), "Gemini CLI quota queries were removed")
        model.refreshQuota(gemini)
        XCTAssertNil(model.quotas[gemini.id])
        XCTAssertFalse(model.refreshingQuotas.contains(gemini.id))

        // The Antigravity CLI is never queried in the background; a manual refresh runs it once.
        let agyData = root.appendingPathComponent("antigravity-cli")
        try FileManager.default.createDirectory(at: agyData, withIntermediateDirectories: true)
        XCTAssertTrue(model.importLocal(LocalProviderCandidate(name: "Antigravity CLI", app: .antigravity, profilePath: agyData.path,
                                                               configuration: .init(kind: .terminal, target: "/usr/bin/true"))))
        let antigravity = try XCTUnwrap(model.accounts.first { $0.app == .antigravity })
        model.refreshQuotas()
        XCTAssertFalse(model.refreshingQuotas.contains(antigravity.id))
        XCTAssertNil(model.providerUsageErrors[antigravity.id])
        model.refreshQuota(antigravity)
        XCTAssertTrue(model.refreshingQuotas.contains(antigravity.id))
        let answered = expectation(for: NSPredicate { _, _ in model.providerUsageErrors[antigravity.id] != nil }, evaluatedWith: nil)
        wait(for: [answered], timeout: 5)
        XCTAssertTrue(model.providerUsageErrors[antigravity.id]?.contains("默认登录目录") == true)

        let reloaded = makeStore(root)
        try reloaded.load()
        XCTAssertEqual(reloaded.accounts.count, 4)
        XCTAssertEqual(reloaded.accounts.first { $0.id == codex.id }, codex)
        XCTAssertEqual(reloaded.accounts.first { $0.id == claude.id }, claude)
        XCTAssertEqual(reloaded.accounts.first { $0.id == gemini.id }?.localProvider, gemini.localProvider)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.removedAccountsURL.path))
    }

    func testRescanOffersMovedLaunchLocationAndUpdatesTheAccountInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-provider-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let data = root.appendingPathComponent(".gemini/antigravity-cli")
        let bin = root.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func executable(_ url: URL) throws {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let oldTarget = root.appendingPathComponent("old/agy")
        try fm.createDirectory(at: oldTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executable(oldTarget)
        let store = makeStore(root)
        try store.load()
        let model = makeModel(store)
        XCTAssertTrue(model.importLocal(LocalProviderCandidate(name: "Antigravity CLI", app: .antigravity, profilePath: data.path,
                                                               configuration: .init(kind: .terminal, target: oldTarget.path))))
        let account = try XCTUnwrap(model.accounts.first)

        // The client moves: the old path is gone and agy now lives in ~/.local/bin.
        try fm.removeItem(at: oldTarget)
        try executable(bin.appendingPathComponent("agy"))
        model.scanLocalProviders()
        XCTAssertFalse(model.localCandidates.contains { $0.app == .antigravity }, "the same data directory is not offered twice")
        let update = try XCTUnwrap(model.localLaunchUpdates.first)
        XCTAssertEqual(update.account.id, account.id)
        XCTAssertEqual(update.configuration.target, bin.appendingPathComponent("agy").path)

        XCTAssertTrue(model.updateLocalLaunch(update))
        XCTAssertEqual(model.accounts.map(\.id), [account.id])
        XCTAssertEqual(model.accounts.first?.localProvider?.target, bin.appendingPathComponent("agy").path)
        XCTAssertTrue(model.localLaunchUpdates.isEmpty)
        let reloaded = makeStore(root)
        try reloaded.load()
        XCTAssertEqual(reloaded.accounts.first?.localProvider?.target, bin.appendingPathComponent("agy").path)
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
        let local = try store.importLocal(LocalProviderCandidate(name: "示例 Gemini CLI", app: .gemini, profilePath: root.path,
            configuration: .init(kind: .terminal, target: "/usr/bin/true", arguments: ["--example"], workingDirectory: root.path)))
        let model = makeModel(store)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
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
        }, to: directory.appendingPathComponent("provider-usage.png"))
        try render(VStack(spacing: 8) {
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
