import Foundation
import CryptoKit
import Darwin

public enum MootInstallState: String, Codable, Sendable { case notInstalled, installed, updating, pendingUninstall, failed }
public enum MootUninstallPolicy: Sendable { case afterRunsFinish, cancelRuns }
public struct MootInstallReceipt: Codable, Sendable {
    public var version: String
    public var architecture: String
    public var ownedFiles: [String]
    public var skillLinks: [String: String]
    public var backupRefs: [String]
    public var state: MootInstallState
}
public struct MootPackageManifest: Codable {
    public var version: String
    public var protocolVersion: Int
    public var platform: String
    public var architecture: String
    public var minOS: Int
    public var files: [String: String]
}
public struct MootInstaller: Sendable {
    public var paths: MootPaths
    public init(paths: MootPaths = MootPaths()) { self.paths = paths }
    public func receipt() -> MootInstallReceipt? { guard let data = try? Data(contentsOf: paths.receipt) else { return nil }; return try? JSONDecoder().decode(MootInstallReceipt.self, from: data) }
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    public func install(package: URL) async throws -> MootInstallReceipt {
        let paths = self.paths
        return try await Task.detached {
            let fm = FileManager.default
            let manifest = try JSONDecoder().decode(MootPackageManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
            guard manifest.protocolVersion == 1, manifest.platform == "macos", manifest.architecture == Self.architecture,
                  manifest.minOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                  manifest.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
                throw MootRPCError(code: "incompatiblePackage", message: "扩展包版本或架构不兼容")
            }
            guard manifest.files["node"] != nil, manifest.files["moot"] != nil, manifest.files["bin/moot.js"] != nil, manifest.files["PerchMootCredentials"] != nil else { throw MootRPCError(code: "invalidPackage", message: "扩展包缺少执行入口") }
            try fm.createDirectory(at: paths.versions, withIntermediateDirectories: true)
            let lock = paths.root.appendingPathComponent(".install-lock")
            try fm.createDirectory(at: lock, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: lock) }
            guard MootInstaller(paths: paths).receipt()?.state != .pendingUninstall else { throw MootRPCError(code: "pendingUninstall", message: "正在等待任务结束并卸载，完成后可重新安装") }
            let staging = paths.versions.appendingPathComponent(".stage-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (relative, digest) in manifest.files {
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\\") else { throw MootRPCError(code: "invalidPackage", message: "扩展包路径无效") }
                let source = package.appendingPathComponent(relative)
                let canonical = source.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(package.resolvingSymlinksInPath().path + "/"),
                      try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MootRPCError(code: "invalidPackage", message: "扩展包包含无效文件") }
                let bytes = try Data(contentsOf: source)
                guard Self.digest(bytes) == digest else { throw MootRPCError(code: "checksumMismatch", message: "扩展包校验失败：" + relative) }
                let target = staging.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
            // Every installation gets its own path: even same-version local updates cannot alter running workers.
            let name = manifest.version + "-" + UUID().uuidString
            let destination = paths.versions.appendingPathComponent(name)
            try fm.moveItem(at: staging, to: destination)
            let temporaryLink = paths.root.appendingPathComponent(".current-" + UUID().uuidString)
            try fm.createSymbolicLink(atPath: temporaryLink.path, withDestinationPath: "versions/" + name)
            guard rename(temporaryLink.path, paths.root.appendingPathComponent("current").path) == 0 else { throw MootRPCError(code: "installFailed", message: "无法激活扩展版本") }
            var receipt = MootInstaller(paths: paths).receipt() ?? MootInstallReceipt(version: manifest.version, architecture: manifest.architecture, ownedFiles: [], skillLinks: [:], backupRefs: [], state: .installed)
            receipt.version = manifest.version; receipt.architecture = manifest.architecture; receipt.state = .installed
            receipt.ownedFiles.append(destination.path)
            try JSONEncoder().encode(receipt).write(to: paths.receipt, options: .atomic)
            try? fm.removeItem(at: paths.root.appendingPathComponent("quiesce.json"))
            let installer = MootInstaller(paths: paths)
            let skillRoots = Set(receipt.skillLinks.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() })
            // Refresh unchanged managed copies. A modified family remains untouched and recoverable.
            for directory in skillRoots { try? installer.installSkills(in: directory) }
            return installer.receipt() ?? receipt
        }.value
    }
    public func installSkills(in directory: URL) throws {
        var receipt = receipt()
        guard receipt?.state == .installed else { throw MootRPCError(code: "notInstalled", message: "先安装 Moot") }
        let fm = FileManager.default
        var prepared: [(URL, Data, Data?)] = []
        for name in ["moot-delegate", "moot-review", "moot-roundtable"] {
            let folder = directory.appendingPathComponent(name), target = folder.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: folder.path), receipt?.skillLinks[target.path] == nil { throw MootRPCError(code: "skillConflict", message: "已有个人技能：\(name)。请先查看迁移预览，未覆盖。") }
            let existing = try? Data(contentsOf: target)
            if let old = receipt?.skillLinks[target.path], let existing, Self.digest(existing) != old { throw MootRPCError(code: "skillModified", message: "技能已被手动修改，保留现有内容：\(name)") }
            let source = paths.root.appendingPathComponent("current/skills/\(name)/SKILL.md")
            let text = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "__MOOT_EXECUTABLE__", with: paths.executable.path)
            prepared.append((target, Data(text.utf8), existing))
        }
        var written: [(URL, Data?)] = []
        do {
            for (target, data, existing) in prepared {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic); written.append((target, existing)); receipt?.skillLinks[target.path] = Self.digest(data)
            }
            try JSONEncoder().encode(receipt).write(to: paths.receipt, options: .atomic)
        } catch {
            for (target, previous) in written.reversed() {
                if let previous { try? previous.write(to: target, options: .atomic) }
                else { try? fm.removeItem(at: target); if (try? fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).isEmpty) == true { try? fm.removeItem(at: target.deletingLastPathComponent()) } }
            }
            throw error
        }
    }

    public func uninstall(policy: MootUninstallPolicy) async throws -> MootInstallState {
        let client = MootRPCClient(paths: paths)
        let active = try await client.call(.init(operation: "runtime.quiesce"))
        if policy == .cancelRuns {
            for id in active.data?["activeRunIDs"].items ?? [] { _ = try await client.call(.init(operation: "run.cancel", payload: .object(["runID": id]))) }
        }
        _ = try await client.call(.init(operation: "runtime.uninstall"))
        return .pendingUninstall
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
