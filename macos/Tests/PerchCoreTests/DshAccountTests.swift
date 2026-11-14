import XCTest
@testable import PerchCore

final class DshAccountTests: XCTestCase {
    private func fixture(_ body: (AccountStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dsh-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root.appendingPathComponent("perch"),
                                 agentDeskProfiles: root.appendingPathComponent("absent.json"), home: root.path)
        try store.load()
        try body(store, root)
    }

    func testWebCapabilityMergesCanonicalHomeAndPreservesNativeAccount() throws {
        try fixture { store, root in
            let data = root.appendingPathComponent("original-dsh")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let native = try store.importLocal(.init(name: "Original Desktop", app: .deepseek, profilePath: data.path,
                configuration: .init(kind: .terminal, target: "/usr/bin/true", arguments: ["web"])))
            let codex = try store.create(name: "Codex", app: .codex)
            let alias = root.appendingPathComponent("alias-dsh")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: data)
            let web = try store.configureDsh(name: "New label must not replace the original", home: alias.path,
                                             configuration: .init(mode: .npm, installationPath: "/tmp/dsh"))
            XCTAssertEqual(web.id, native.id)
            XCTAssertEqual(web.name, native.name)
            XCTAssertEqual(web.localProvider, native.localProvider)
            XCTAssertEqual(web.profilePath, native.profilePath)
            XCTAssertEqual(web.sessionRoot, native.sessionRoot)
            XCTAssertEqual(web.createdAt, native.createdAt)
            XCTAssertEqual(store.accounts.map(\.id), [native.id, codex.id])
            try store.load()
            let restored = try XCTUnwrap(store.accounts.first)
            // The existing account format persists ISO 8601 milliseconds, while Date() has finer precision.
            XCTAssertEqual(restored.createdAt.timeIntervalSince1970, web.createdAt.timeIntervalSince1970, accuracy: 0.001)
            var expected = web
            expected.createdAt = restored.createdAt
            XCTAssertEqual(restored, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.removedAccountsURL.path))
        }
    }

    func testExternalBalanceHomeAssociatesExistingAccountWithoutDuplicate() throws {
        try fixture { store, root in
            let data = root.appendingPathComponent(".dsh")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let native = try store.importLocal(.init(name: "Local dsh", app: .deepseek, profilePath: data.path,
                configuration: .init(kind: .terminal, target: "/usr/bin/true")))
            let web = try store.configureDsh(name: "External", home: "", configuration: .init(mode: .external, balanceHome: data.path))
            XCTAssertEqual(web.id, native.id)
            XCTAssertEqual(store.accounts.count, 1)
            XCTAssertEqual(web.dshWeb?.balanceHome, data.resolvingSymlinksInPath().path)
        }
    }

    func testRemovingWebAccountNeverTrashesHomeAndHomeCannotBeRelocated() throws {
        try fixture { store, root in
            let account = try store.configureDsh(name: "Web", home: "", configuration: .init(mode: .npm))
            let file = URL(fileURLWithPath: account.profilePath).appendingPathComponent("preserve.txt")
            try Data("owner data".utf8).write(to: file)
            XCTAssertThrowsError(try store.relocate(id: account.id, profilePath: root.appendingPathComponent("other").path))
            XCTAssertThrowsError(try store.configureDsh(name: "Web", home: root.appendingPathComponent("other").path,
                                                        configuration: .init(mode: .npm), accountID: account.id))
            try store.delete(id: account.id, moveDataToTrash: true)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "owner data")
        }
    }

    func testExternalWithoutHomeHasPrivateIdentityAndOldAccountsDecode() throws {
        try fixture { store, _ in
            let old = try store.create(name: "Existing", app: .claude)
            let data = try AccountStore.encoder.encode(old)
            let decoded = try AccountStore.decoder.decode(Account.self, from: data)
            XCTAssertNil(decoded.dshWeb)
            let account = try store.configureDsh(name: "Web", home: "", configuration: .init(mode: .external))
            XCTAssertTrue(account.profilePath.hasPrefix(store.root.appendingPathComponent("DshConnections").path))
            XCTAssertEqual(account.dshWeb?.balanceHome, "")
            let attributes = try FileManager.default.attributesOfItem(atPath: account.profilePath)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let persisted = try String(contentsOf: store.fileURL, encoding: .utf8)
            XCTAssertFalse(persisted.contains("token="))
            XCTAssertFalse(persisted.contains("cookie"))
            XCTAssertThrowsError(try store.configureDsh(name: "Bad", home: "relative/home", configuration: .init(mode: .npm)))
        }
    }
}
