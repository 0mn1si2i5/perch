import XCTest
@testable import PerchCore

final class LocalProviderTests: XCTestCase {
    func testNativeGeminiIsDiscoveredAsItsOwnProviderWithoutImportingIt() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Applications/Gemini.app/Contents")
        let profile = root.appendingPathComponent("Library/Application Support/com.google.GeminiMacOS")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.google.GeminiMacOS"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let store = AccountStore(root: root.appendingPathComponent("Perch"), home: root.path)
        try store.load()
        let candidates = LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: [root.appendingPathComponent("Applications")])
        let candidate = try XCTUnwrap(candidates.first { $0.app == .geminiApp })
        XCTAssertEqual(candidate.name, "Gemini")
        XCTAssertEqual(candidate.profilePath, profile.path)
        XCTAssertEqual(candidate.configuration.kind, .application)
        XCTAssertTrue(store.accounts.isEmpty, "Discovery is read-only; adding requires an explicit choice")
        let account = try store.importLocal(candidate)
        XCTAssertEqual(account.app, .geminiApp)
        let decoded = try AccountStore.decoder.decode(Account.self, from: AccountStore.encoder.encode(account))
        XCTAssertEqual(decoded.app, .geminiApp)
        XCTAssertEqual(decoded.profilePath, account.profilePath)
        XCTAssertEqual(decoded.localProvider, account.localProvider)
        XCTAssertThrowsError(try store.importLocal(candidate))
    }

    func testDeepSeekPrefersInstalledDesktopOverOldCLIWithoutChangingCredentials() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Applications/DSH Desktop.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ai.deepseek.dsh.desktop", "CFBundleExecutable": "DSH Desktop"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let data = root.appendingPathComponent(".dsh")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let credentials = data.appendingPathComponent(".credentials.yaml")
        try Data("version: 1\nrecords: {}\nrefs: {}\n".utf8).write(to: credentials)
        let candidates = LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: [root.appendingPathComponent("Applications")])
        let desktop = try XCTUnwrap(candidates.first { $0.app == .deepseek })
        XCTAssertEqual(desktop.configuration.kind, .application)
        XCTAssertTrue(desktop.configuration.arguments.isEmpty)
        XCTAssertEqual(desktop.profilePath, data.path)
        XCTAssertEqual(try String(contentsOf: credentials, encoding: .utf8), "version: 1\nrecords: {}\nrefs: {}\n")
        let account = Account(id: "desktop", name: "Desktop", app: .deepseek, profilePath: data.path, sessionRoot: data.path,
                              createdAt: Date(), lastLaunchedAt: nil, localProvider: desktop.configuration)
        let command = try LocalProviderLauncher.command(for: account)
        XCTAssertEqual(command.arguments, ["-a", desktop.configuration.target])
        let executable = contents.appendingPathComponent("MacOS/DSH Desktop").path
        XCTAssertTrue(LocalProviderLauncher.isRunning(account, processes: [.init(pid: 1, args: executable)]))
        XCTAssertFalse(LocalProviderLauncher.isRunning(account, processes: [.init(pid: 1, args: "/usr/bin/open -a " + executable)]))
        let alternate = root.appendingPathComponent("alternate-home")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("Library/Application Support/DSH Desktop/data-directory/state.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "activeHome": alternate.path]).write(to: state)
        XCTAssertEqual(LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: [root.appendingPathComponent("Applications")])
            .first { $0.app == .deepseek }?.profilePath, alternate.path)
        try Data("invalid".utf8).write(to: state)
        XCTAssertFalse(LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: [root.appendingPathComponent("Applications")])
            .contains { $0.app == .deepseek })
    }

    func testDiscoveryRequiresInstalledExecutableAndExistingDataAndUsesDSHProfile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["gemini", "agy", "dsh"] {
            let executable = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        XCTAssertTrue(LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: []).isEmpty)
        for path in [".gemini/antigravity-cli", ".dsh"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = LocalProviderDiscovery.scan(home: root.path, path: "", applicationRoots: [])
        XCTAssertEqual(found.map(\.app), [.gemini, .antigravity, .deepseek])
        XCTAssertEqual(found.last?.configuration.arguments, ["--profile", "web", "--host", "127.0.0.1", "--port", "3080"])
    }

    func testLegacyAndNewAccountsRoundTripWithoutTouchingReferencedData() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root.appendingPathComponent("Perch"))
        try store.load()
        let legacy = try store.create(name: "Existing", app: .codex)
        let client = root.appendingPathComponent("client-data")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        let sentinel = client.appendingPathComponent("auth.txt")
        try Data("test-fixture".utf8).write(to: sentinel)
        let candidate = LocalProviderCandidate(name: "Local", app: .gemini, profilePath: client.path,
                                               configuration: .init(kind: .terminal, target: "/bin/echo"))
        let local = try store.importLocal(candidate)
        XCTAssertThrowsError(try store.importLocal(candidate))
        try store.load()
        XCTAssertEqual(store.accounts.map(\.id), [legacy.id, local.id])
        XCTAssertNil(store.accounts[0].localProvider)
        XCTAssertEqual(store.accounts[1].localProvider, candidate.configuration)
        try store.delete(id: local.id, moveDataToTrash: true)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "test-fixture")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testOldJSONWithoutProviderFieldsStillDecodes() throws {
        let json = """
        {"id":"old","name":"Existing","appId":"codex","profilePath":"/profile","sessionRoot":"/home","createdAt":"2026-01-01T00:00:00Z"}
        """
        let decoded = try AccountStore.decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.app, .codex)
        XCTAssertNil(decoded.localProvider)
    }

    func testTerminalScriptActuallyPreservesLiteralArgumentsAndCleansMarker() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = "hello ' \" $HOME $(touch SHOULD_NOT_EXIST); `id`\nsecond line"
        let account = Account(id: "../../escape", name: "Test", app: .antigravity, profilePath: root.path, sessionRoot: root.path,
                              createdAt: Date(), lastLaunchedAt: nil,
                              localProvider: .init(kind: .terminal, target: "/usr/bin/printf", arguments: ["%s", payload], workingDirectory: root.path))
        let command = try LocalProviderLauncher.command(for: account, directory: root)
        let script = LocalProviderLauncher.scriptURL(for: account, directory: root)
        XCTAssertEqual(command.arguments, ["-a", "Terminal", script.path])
        XCTAssertEqual(script.deletingLastPathComponent().path, root.path)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.appendingPathExtension("pid").path))
    }

    func testProviderHomeSemanticsAndRunningMarkerRejectsReusedPID() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var account = Account(id: "test", name: "Test", app: .gemini, profilePath: root.appendingPathComponent(".gemini").path,
                              sessionRoot: "", createdAt: Date(), lastLaunchedAt: nil,
                              localProvider: .init(kind: .terminal, target: "/bin/echo"))
        let script = try LocalProviderLauncher.script(for: account, directory: root)
        XCTAssertTrue(script.contains("export GEMINI_CLI_HOME=" + LocalProviderLauncher.quote(root.path)))
        account.app = .deepseek
        XCTAssertTrue(try LocalProviderLauncher.script(for: account, directory: root).contains("export DSH_HOME=" + LocalProviderLauncher.quote(account.profilePath)))
        let url = LocalProviderLauncher.scriptURL(for: account, directory: root)
        try Data("42\n".utf8).write(to: url.appendingPathExtension("pid"))
        XCTAssertFalse(LocalProviderLauncher.isRunning(account, processes: [.init(pid: 42, args: "/bin/sleep 60")], directory: root))
        XCTAssertTrue(LocalProviderLauncher.isRunning(account, processes: [.init(pid: 42, args: "/bin/zsh " + url.path)], directory: root))
    }

    func testScanOffersNewLaunchLocationAndUpdateKeepsDataAndArguments() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root.appendingPathComponent("Perch"))
        try store.load()
        let data = root.appendingPathComponent("antigravity-cli")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let old = try store.importLocal(LocalProviderCandidate(name: "Antigravity CLI", app: .antigravity, profilePath: data.path,
            configuration: .init(kind: .terminal, target: "/bin/echo", arguments: ["--keep"], workingDirectory: root.path)))
        func candidate(_ kind: LocalLaunchKind, _ target: String, profile: String? = nil) -> LocalProviderCandidate {
            LocalProviderCandidate(name: "Antigravity CLI", app: .antigravity, profilePath: profile ?? data.path,
                                   configuration: .init(kind: kind, target: target))
        }
        XCTAssertNil(LocalProviderDiscovery.launchUpdate(for: old, candidate: candidate(.terminal, "/bin/echo")))
        XCTAssertNil(LocalProviderDiscovery.launchUpdate(for: old, candidate: candidate(.terminal, "/bin/cat", profile: root.path)))
        let update = try XCTUnwrap(LocalProviderDiscovery.launchUpdate(for: old, candidate: candidate(.terminal, "/bin/cat")))
        XCTAssertEqual(update.configuration, .init(kind: .terminal, target: "/bin/cat", arguments: ["--keep"], workingDirectory: root.path))
        XCTAssertEqual(LocalProviderDiscovery.launchUpdate(for: old, candidate: candidate(.application, "/System/Applications/Calculator.app"))?
            .configuration, .init(kind: .application, target: "/System/Applications/Calculator.app"))

        XCTAssertThrowsError(try store.updateLocalLaunch(id: old.id, configuration: .init(kind: .terminal, target: "/missing/agy")))
        XCTAssertEqual(store.accounts.first?.localProvider, old.localProvider)
        try store.updateLocalLaunch(id: old.id, configuration: update.configuration)
        try store.load()
        XCTAssertEqual(store.accounts.map(\.id), [old.id])
        XCTAssertEqual(store.accounts[0].localProvider, update.configuration)
        XCTAssertEqual(store.accounts[0].profilePath, data.path)
        XCTAssertEqual(store.accounts[0].name, old.name)
    }

    func testMovedClientLaunchFailureSaysHowToRepairIt() {
        let account = Account(id: "moved", name: "Antigravity CLI", app: .antigravity, profilePath: "/tmp", sessionRoot: "/tmp",
                              createdAt: Date(), lastLaunchedAt: nil, localProvider: .init(kind: .terminal, target: "/missing/agy"))
        let launcher = Launcher(activate: { _ in true }, processes: { [] }, run: { _ in XCTFail("must not run a moved client") })
        guard case .failed(let text) = launcher.launch(account) else { return XCTFail("expected a launch failure") }
        XCTAssertTrue(text.hasPrefix("找不到可执行文件 /missing/agy"))
        XCTAssertTrue(text.contains("更新启动位置"))
        XCTAssertTrue(text.contains("删除后重新扫描添加"))
    }
}
