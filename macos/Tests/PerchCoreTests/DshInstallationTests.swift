import XCTest
@testable import PerchCore

final class DshInstallationTests: XCTestCase {
    func testNvmVersionsSortNumericallyForFinderLaunches() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["v9.11.2", "v24.9.0", "v24.10.0"] {
            let bin = root.appendingPathComponent(".nvm/versions/node/" + version + "/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try executable(bin.appendingPathComponent("node"))
        }
        let directories = DshInstallation.nvmDirectories(home: root.path)
        XCTAssertEqual(directories.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
                       ["v24.10.0", "v24.9.0", "v9.11.2"])
        // Supplying only these directories keeps the test independent of the developer's installed Node.
        XCTAssertEqual(DshInstallation.findNode(home: root.path, path: directories.joined(separator: ":")),
                       root.appendingPathComponent(".nvm/versions/node/v24.10.0/bin/node").path)
    }

    func testHomeInputUsesOneCanonicalPathForCheckAndLaunch() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("account data")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: actual)
        for input in ["~/alias", "$HOME/alias", "${HOME}/alias", "\"$HOME/alias\"", "'$HOME/alias'"] {
            XCTAssertEqual(try DshInstallation.normalize(input, home: root.path, environment: [:]), actual.path)
        }
        XCTAssertThrowsError(try DshInstallation.normalize("relative/home", home: root.path, environment: [:]))
        XCTAssertThrowsError(try DshInstallation.normalize("$MISSING/path", home: root.path, environment: [:]))
        XCTAssertThrowsError(try DshInstallation.normalize("/tmp/\0bad"))
    }

    func testNpmSymlinkAndNvmDiscoveryKeepTheirAssociatedNode() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent(".nvm/versions/node/v24.9.0")
        let package = prefix.appendingPathComponent("lib/node_modules/@deepseek-ai/dsh")
        try makePackage(package)
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try executable(node)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("dsh"), withDestinationURL: package.appendingPathComponent("lib/main.js"))
        let inspected = try XCTUnwrap(DshInstallation.inspect(bin.appendingPathComponent("dsh").path))
        XCTAssertEqual(inspected.path, package.path)
        XCTAssertEqual(inspected.node, node.path)
        XCTAssertEqual(inspected.nodeRequirement, ">=24.9.0")
        let discovered = DshInstallation.discover(home: root.path, path: bin.path, environment: [:])
        XCTAssertEqual(discovered.filter { $0.path == package.path }.count, 1)
        XCTAssertTrue(DshInstallation.discover(home: root.path, path: "", environment: [:]).contains { $0.path == package.path })
    }

    func testNpmrcAndNpxDiscoveryAreReadOnlyAndIgnoreBrokenPackages() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("custom prefix/lib/node_modules/@deepseek-ai/dsh")
        let cached = root.appendingPathComponent("custom cache/_npx/entry/node_modules/@deepseek-ai/dsh")
        try makePackage(global)
        try makePackage(cached)
        let broken = root.appendingPathComponent("custom cache/_npx/broken/node_modules/@deepseek-ai/dsh")
        try makePackage(broken)
        try FileManager.default.removeItem(at: broken.appendingPathComponent("lib/main.js"))
        let npmrc = "prefix=${HOME}/custom prefix\ncache=\"${HOME}/custom cache\"\n//registry.example/:_authToken=do-not-use\n"
        try Data(npmrc.utf8).write(to: root.appendingPathComponent(".npmrc"))
        let found = DshInstallation.discover(home: root.path, path: "relative:.", environment: [:])
        XCTAssertTrue(found.contains { $0.path == global.path })
        XCTAssertTrue(found.contains { $0.path == cached.path })
        XCTAssertFalse(found.contains { $0.path == broken.path })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".npmrc"), encoding: .utf8), npmrc)
    }

    func testSourceLaunchUsesLiteralArgumentsAndRequiresWebBuild() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source ' with spaces")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "@deepseek-ai/dsh-root"])
            .write(to: source.appendingPathComponent("package.json"))
        try makePackage(source.appendingPathComponent("apps/cli"))
        let node = root.appendingPathComponent("node")
        try executable(node)
        let home = root.appendingPathComponent("DSH home")
        var account = webAccount(home: home.path, configuration: .init(mode: .source, installationPath: source.path, nodePath: node.path))
        XCTAssertEqual(DshInstallation.inspect(source.path)?.mode, .source)
        XCTAssertEqual(DshInstallation.inspect(source.appendingPathComponent("package.json").path)?.mode, .source)
        XCTAssertThrowsError(try DshInstallation.resolve(account: account))
        let html = source.appendingPathComponent("apps/web/dist/index.html")
        try FileManager.default.createDirectory(at: html.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: html)
        let launch = try DshInstallation.resolve(account: account)
        XCTAssertEqual(launch.arguments, [source.appendingPathComponent("apps/cli/lib/main.js").path,
                                         "--profile", "web", "--host", "127.0.0.1", "--port", "0", "--no-open"])
        XCTAssertEqual(launch.environment["DSH_HOME"], home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "Resolving a launch must not create user data")
        account.dshWeb?.profile = "../desktop"
        XCTAssertThrowsError(try DshInstallation.resolve(account: account))
        account.dshWeb?.profile = "desktop"
        XCTAssertThrowsError(try DshInstallation.resolve(account: account))
        account.dshWeb?.profile = "custom"
        XCTAssertThrowsError(try DshInstallation.resolve(account: account))
        let custom = home.appendingPathComponent("profiles/custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: custom.appendingPathComponent("package.json"))
        XCTAssertEqual(try DshInstallation.resolve(account: account).profile, "custom")
    }

    func testResolveRejectsNonExecutableNodeAndEscapingManifestEntry() throws {
        let root = try makeTempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try makePackage(package)
        let node = root.appendingPathComponent("node")
        try Data("fixture".utf8).write(to: node)
        let account = webAccount(home: root.appendingPathComponent("home").path,
                                 configuration: .init(installationPath: package.path, nodePath: node.path))
        XCTAssertThrowsError(try DshInstallation.resolve(account: account))
        try JSONSerialization.data(withJSONObject: ["name": "@deepseek-ai/dsh", "bin": ["dsh": "../node"]])
            .write(to: package.appendingPathComponent("package.json"))
        XCTAssertNil(DshInstallation.inspect(package.path))
    }

    private func makePackage(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let value: [String: Any] = ["name": "@deepseek-ai/dsh", "version": "0.2.1-test", "engines": ["node": ">=24.9.0"], "bin": ["dsh": "lib/main.js"]]
        try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("package.json"))
        try Data("// fixture only".utf8).write(to: directory.appendingPathComponent("lib/main.js"))
    }
    private func executable(_ file: URL) throws {
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    private func webAccount(home: String, configuration: DshConfiguration) -> Account {
        var account = Account(id: "fixture", name: "Fixture", app: .deepseek, profilePath: home, sessionRoot: home,
                              createdAt: Date(), lastLaunchedAt: nil)
        account.dshWeb = configuration
        return account
    }
}
