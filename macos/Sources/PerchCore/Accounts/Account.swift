import Foundation

public enum AppKind: String, Codable, CaseIterable {
    case codex, claude, gemini, geminiApp, antigravity, deepseek, claudeCode
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
        case .claudeCode: return "Claude Code CLI"
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
    /// Claude Code CLI on a Console organization: its credit grants, as listed in the Console billing history.
    public var creditGrants: [CreditGrant]?
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, app = "appId", profilePath, sessionRoot, createdAt, lastLaunchedAt, localProvider, creditGrants
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

/// One Console credit grant: an amount in USD usable from `grantedOn` through `expiresOn` (UTC dates, `yyyy-MM-dd`).
public struct CreditGrant: Codable, Equatable {
    public var amount: Double
    public var grantedOn: String
    public var expiresOn: String

    public init(amount: Double, grantedOn: String, expiresOn: String) {
        self.amount = amount; self.grantedOn = grantedOn; self.expiresOn = expiresOn
    }

    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    /// UTC midnight at the start of `grantedOn`.
    public var start: Date { Self.day(grantedOn) ?? .distantFuture }
    /// UTC midnight after `expiresOn`: the expiry day itself is still usable.
    public var end: Date { Self.day(expiresOn).map { $0.addingTimeInterval(86_400) } ?? .distantPast }
    public var isValid: Bool { amount.isFinite && amount > 0 && Self.day(grantedOn) != nil && Self.day(expiresOn) != nil && start < end }

    /// One grant per line: `amount grantedOn expiresOn`, e.g. `157.94 2026-11-06 2026-12-09`. A `$` is allowed.
    public static func parse(_ text: String) -> [CreditGrant]? {
        var grants: [CreditGrant] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.replacingOccurrences(of: "$", with: "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard !parts.isEmpty else { continue }
            guard parts.count == 3, let amount = Double(parts[0]) else { return nil }
            let grant = CreditGrant(amount: amount, grantedOn: String(parts[1]), expiresOn: String(parts[2]))
            guard grant.isValid else { return nil }
            grants.append(grant)
        }
        return grants
    }

    public static func format(_ grants: [CreditGrant]) -> String {
        grants.map { String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), $0.amount) + " " + $0.grantedOn + " " + $0.expiresOn }
            .joined(separator: "\n")
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
