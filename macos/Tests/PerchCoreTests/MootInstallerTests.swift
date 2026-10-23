import XCTest
import CryptoKit
@testable import PerchCore
final class MootInstallerTests: XCTestCase {
    func testInvalidPackageLeavesCurrentVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("versions/old"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/old")
        let package = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let installer = MootInstaller(paths: MootPaths(root: root))
        do { _ = try await installer.install(package: package); XCTFail("Invalid package accepted") } catch {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path), "versions/old")
    }
    func testUpdateLeavesPinnedPreviousVersionIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package"), managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for name in ["node", "moot", "bin/moot.js", "PerchMootCredentials"] {
            let bytes = Data("test payload".utf8); try bytes.write(to: package.appendingPathComponent(name)); files[name] = MootInstaller.digest(bytes)
        }
        let manifest = MootPackageManifest(version: "0.1.0", protocolVersion: 1, platform: "macos", architecture: MootInstaller.architecture, minOS: 14, files: files)
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let installer = MootInstaller(paths: MootPaths(root: managed))
        let first = try await installer.install(package: package)
        let second = try await installer.install(package: package)
        XCTAssertEqual(second.ownedFiles.count, 2)
        XCTAssertNotEqual(first.ownedFiles.first, second.ownedFiles.last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.ownedFiles[0] + "/node"))
    }
}
