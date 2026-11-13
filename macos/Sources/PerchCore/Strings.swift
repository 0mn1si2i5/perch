import Foundation

/// Both platforms ship shared/strings/zh-CN.json; no dialogue is duplicated in Swift.
public enum Strings {
    public static let all: [String: String] = {
        do { return try load(bundle: .main) }
        catch { preconditionFailure("无法加载共享文案 zh-CN.json：\(error)") }
    }()

    static func load(bundle: Bundle) throws -> [String: String] {
        let url: URL
        if let resource = bundle.url(forResource: "zh-CN", withExtension: "json") {
            url = resource
        } else if bundle.bundleURL.pathExtension != "app" {
            // swift test / swift run have no app bundle. Read the canonical source file.
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("shared/strings/zh-CN.json")
        } else {
            // A packaged app must carry its resources, even on a development machine.
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    public static func get(_ key: String) -> String {
        guard let value = all[key] else { preconditionFailure("缺少共享文案键：\(key)") }
        return value
    }

    /// Pet templates share one literal {0} placeholder with Windows.
    public static func format(_ key: String, _ argument: String) -> String {
        get(key).replacingOccurrences(of: "{0}", with: argument)
    }
}
