import Foundation

/// User-facing text shared with Windows, read from shared/strings/zh-CN.json.
/// The app bundle carries the file in Resources; `swift test` and `swift run` read it from the repository.
public enum Strings {
    public static let all: [String: String] = load()

    public static func get(_ key: String) -> String {
        guard let value = all[key] else {
            assertionFailure("Missing shared string: \(key)")
            return key
        }
        return value
    }

    static var sourceURL: URL? {
        if let bundled = Bundle.main.url(forResource: "zh-CN", withExtension: "json", subdirectory: "strings") { return bundled }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/strings/zh-CN.json")
        return FileManager.default.fileExists(atPath: repository.path) ? repository : nil
    }

    private static func load() -> [String: String] {
        guard let url = sourceURL, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            fatalError("Missing shared strings resource (strings/zh-CN.json)")
        }
        return values
    }
}
