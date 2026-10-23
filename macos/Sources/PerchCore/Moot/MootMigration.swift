import Foundation
public struct MootMigrationProposal { public var paths: [URL] }
public struct MootMigrationReceipt: Codable { public var moves: [String: String]; public var file: URL }
public struct MootMigration {
    public var paths: MootPaths
    public init(paths: MootPaths = MootPaths()) { self.paths = paths }
    public func inspect(skillRoot: URL) -> MootMigrationProposal {
        .init(paths: ["codex-delegate", "gemini-delegate", "moot-delegate", "moot-review", "moot-roundtable"].map { skillRoot.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    public func apply(_ proposal: MootMigrationProposal) throws -> MootMigrationReceipt {
        let fm = FileManager.default, backup = paths.root.appendingPathComponent("backups/skills-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var receipt = MootMigrationReceipt(moves: [:], file: backup.appendingPathComponent("migration.json"))
        do {
            for (index, source) in proposal.paths.enumerated() {
                let target = backup.appendingPathComponent("\(index)-" + source.lastPathComponent)
                try fm.moveItem(at: source, to: target); receipt.moves[source.path] = target.path
                try JSONEncoder().encode(receipt).write(to: receipt.file, options: .atomic)
            }
            return receipt
        } catch { try? restore(receipt); throw error }
    }
    public func restoreManaged(_ receipt: MootMigrationReceipt) throws {
        let fm = FileManager.default
        var installed = MootInstaller(paths: paths).receipt()
        let roots = Set(receipt.moves.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        let folders = roots.flatMap { root in ["moot-delegate", "moot-review", "moot-roundtable"].map { root.appendingPathComponent($0) } }.filter { fm.fileExists(atPath: $0.path) }
        for folder in folders {
            let file = folder.appendingPathComponent("SKILL.md")
            guard let digest = installed?.skillLinks[file.path], let bytes = try? Data(contentsOf: file), MootInstaller.digest(bytes) == digest,
                  (try fm.contentsOfDirectory(atPath: folder.path)) == ["SKILL.md"] else {
                throw MootRPCError(code: "restoreConflict", message: "保留已修改或不属于 Moot 的技能：" + folder.path)
            }
        }
        for (original, backup) in receipt.moves {
            guard fm.fileExists(atPath: backup), !fm.fileExists(atPath: original) || folders.contains(URL(fileURLWithPath: original)) else { throw MootRPCError(code: "restoreConflict", message: "恢复位置冲突或备份缺失：" + original) }
        }
        let displaced = try apply(.init(paths: folders))
        do { try restore(receipt) } catch { try? restore(displaced); throw error }
        for folder in folders { installed?.skillLinks.removeValue(forKey: folder.appendingPathComponent("SKILL.md").path) }
        installed?.backupRefs.append(displaced.file.path)
        if let installed { try JSONEncoder().encode(installed).write(to: paths.receipt, options: .atomic) }
    }
    public func restore(_ receipt: MootMigrationReceipt) throws {
        let fm = FileManager.default
        // Never overwrite a newly created or manually edited skill during restoration.
        for (original, _) in receipt.moves where fm.fileExists(atPath: original) { throw MootRPCError(code: "restoreConflict", message: "恢复位置已有内容：" + original) }
        for (original, backup) in receipt.moves { try fm.moveItem(atPath: backup, toPath: original) }
    }
}
