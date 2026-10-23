import Foundation
public struct MootPaths: Sendable {
    public var root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perch/Extensions/Moot")) { self.root = root }
    public var executable: URL { root.appendingPathComponent("current/moot") }
    public var receipt: URL { root.appendingPathComponent("install-receipt.json") }
    public var versions: URL { root.appendingPathComponent("versions") }
}
