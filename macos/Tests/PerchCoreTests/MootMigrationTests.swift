import XCTest
@testable import PerchCore
final class MootMigrationTests: XCTestCase {
    func testSelectedLegacySkillsCanBeRestoredAndOtherSkillsStay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("skills")
        for name in ["codex-delegate", "my-skill"] {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: skills.appendingPathComponent(name + "/SKILL.md"))
        }
        let migration = MootMigration(paths: MootPaths(root: root.appendingPathComponent("managed")))
        let proposal = migration.inspect(skillRoot: skills)
        XCTAssertEqual(proposal.paths.count, 1)
        let receipt = try migration.apply(proposal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skills.appendingPathComponent("my-skill/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skills.appendingPathComponent("codex-delegate").path))
        try migration.restore(receipt)
        XCTAssertEqual(try String(contentsOf: skills.appendingPathComponent("codex-delegate/SKILL.md"), encoding: .utf8), "codex-delegate")
    }
    func testRestoreReplacesOnlyUnmodifiedManagedFamily() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MootPaths(root: root.appendingPathComponent("managed")), skills = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills.appendingPathComponent("moot-delegate"), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: skills.appendingPathComponent("moot-delegate/SKILL.md"))
        let migration = MootMigration(paths: paths), backup = try migration.apply(migration.inspect(skillRoot: skills))
        var owned: [String: String] = [:]
        for name in ["moot-delegate", "moot-review", "moot-roundtable"] {
            let file = skills.appendingPathComponent(name + "/SKILL.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("managed".utf8); try bytes.write(to: file); owned[file.path] = MootInstaller.digest(bytes)
        }
        let receipt = MootInstallReceipt(version: "0.1.0", architecture: MootInstaller.architecture, ownedFiles: [], skillLinks: owned, backupRefs: [], state: .installed)
        try JSONEncoder().encode(receipt).write(to: paths.receipt)
        let changed = skills.appendingPathComponent("moot-review/SKILL.md")
        try Data("personal".utf8).write(to: changed)
        XCTAssertThrowsError(try migration.restoreManaged(backup))
        XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "personal")
        try Data("managed".utf8).write(to: changed)
        try migration.restoreManaged(backup)
        XCTAssertEqual(try String(contentsOf: skills.appendingPathComponent("moot-delegate/SKILL.md"), encoding: .utf8), "legacy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: changed.path))
        XCTAssertEqual(MootInstaller(paths: paths).receipt()?.skillLinks.count, 0)
    }

}
