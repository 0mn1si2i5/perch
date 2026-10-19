import Foundation

public enum AppKind: String, Codable, CaseIterable {
    case codex, claude, gemini, geminiApp, antigravity, deepseek, custom, api
    public static let desktopClients: [AppKind] = [.codex, .claude]
    public var hasQuota: Bool { Self.desktopClients.contains(self) }
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini CLI"
        case .geminiApp: return "Gemini"
        case .antigravity: return "Antigravity"
        case .deepseek: return "DeepSeek Harness"
        case .custom: return "自定义客户端"
        case .api: return "API 供应商"
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
    public var apiProvider: APIProviderConfiguration?
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, app = "appId", profilePath, sessionRoot, createdAt, lastLaunchedAt, localProvider, apiProvider
    }

    public init(id: String, name: String, app: AppKind, profilePath: String,
                sessionRoot: String, createdAt: Date, lastLaunchedAt: Date?,
                localProvider: LocalProviderConfiguration? = nil, apiProvider: APIProviderConfiguration? = nil) {
        self.id = id; self.name = name; self.app = app
        self.profilePath = profilePath; self.sessionRoot = sessionRoot
        self.createdAt = createdAt; self.lastLaunchedAt = lastLaunchedAt
        self.localProvider = localProvider; self.apiProvider = apiProvider
    }
}

/// ISO 8601 with milliseconds, matching agent-desk's `toISOString()` output.
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
