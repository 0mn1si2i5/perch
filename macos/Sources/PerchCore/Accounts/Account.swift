import Foundation

public enum AppKind: String, Codable, CaseIterable {
    case codex, claude, gemini, geminiApp, antigravity, deepseek
    public static let desktopClients: [AppKind] = [.codex, .claude]
    /// Account types earlier versions stored: API providers and custom clients. `AccountStore.load` moves them to a backup file.
    static let removedRawValues: Set<String> = ["api", "custom"]
    public var hasQuota: Bool { Self.desktopClients.contains(self) }
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini CLI"
        case .geminiApp: return "Gemini"
        case .antigravity: return "Antigravity"
        case .deepseek: return "DeepSeek Harness"
        }
    }

    /// Where the client keeps its data when opened normally (Dock, Finder), without `--user-data-dir`.
    public func defaultProfilePath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/\(displayName)")
    }

    /// The default instance's session root: `~/.codex` for Codex, the profile itself for Claude.
    public func defaultSessionRoot(home: String = NSHomeDirectory()) -> String {
        self == .codex ? (home as NSString).appendingPathComponent(".codex") : defaultProfilePath(home: home)
    }

    /// Session root that belongs with a profile directory.
    public func sessionRoot(forProfile profilePath: String, home: String = NSHomeDirectory()) -> String {
        if profilePath == defaultProfilePath(home: home) { return defaultSessionRoot(home: home) }
        return self == .codex ? (profilePath as NSString).appendingPathComponent("codex-home") : profilePath
    }
}

/// One launchable desktop-client slot. Directories are referenced in place and never moved by Perch.
public struct Account: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var app: AppKind
    /// Chromium user-data-dir passed as `--user-data-dir`.
    public var profilePath: String
    /// CODEX_HOME for Codex; equal to profilePath for Claude.
    public var sessionRoot: String
    public var localProvider: LocalProviderConfiguration?
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, app = "appId", profilePath, sessionRoot, createdAt, lastLaunchedAt, localProvider
    }

    public init(id: String, name: String, app: AppKind, profilePath: String,
                sessionRoot: String, createdAt: Date, lastLaunchedAt: Date?,
                localProvider: LocalProviderConfiguration? = nil) {
        self.id = id; self.name = name; self.app = app
        self.profilePath = profilePath; self.sessionRoot = sessionRoot
        self.createdAt = createdAt; self.lastLaunchedAt = lastLaunchedAt
        self.localProvider = localProvider
    }
}

/// ISO 8601 with milliseconds, as JavaScript's `toISOString()` writes it.
enum ISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
