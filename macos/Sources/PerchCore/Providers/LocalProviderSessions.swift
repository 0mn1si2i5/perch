import Foundation
import SQLite3

public struct LocalProviderSession: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let path: String
    public let updatedAt: Date
    public let status: TaskStatus

    public init(id: String, title: String, path: String, updatedAt: Date, status: TaskStatus) {
        self.id = id; self.title = title; self.path = path
        self.updatedAt = updatedAt; self.status = status
    }
}

/// Local indexes only. Never decrypts credentials or reads compressed conversation bodies.
public enum LocalProviderSessions {
    public static func recent(_ account: Account) -> [LocalProviderSession] {
        guard !account.sessionRoot.isEmpty else { return [] }
        let root = URL(fileURLWithPath: account.sessionRoot, isDirectory: true)
        let sessions: [LocalProviderSession]
        switch account.app {
        case .antigravity: sessions = antigravity(root)
        case .deepseek: sessions = deepseek(root)
        case .gemini: sessions = gemini(root)
        default: return []
        }
        var seen = Set<String>()
        return Array(sessions.sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }.prefix(30))
    }

    private static func antigravity(_ root: URL) -> [LocalProviderSession] {
        let file = root.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        // Deliberately omit preview, raw_summary, and the full-text search tables.
        let sql = "SELECT conversation_id, substr(title,1,500), last_modified_time, status FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 60"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var result: [LocalProviderSession] = []
        let now = Date()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), !id.isEmpty, let updated = date(text(2)) else { continue }
            let status: TaskStatus = text(3) == "CASCADE_RUN_STATUS_RUNNING"
                ? (now.timeIntervalSince(updated) > 30 * 60 ? .interrupted : .running) : .unknown
            result.append(.init(id: id, title: title(text(1)), path: file.path, updatedAt: updated, status: status))
        }
        return result
    }

    private static func deepseek(_ root: URL) -> [LocalProviderSession] {
        children(root.appendingPathComponent("storages/session_projcache/sessions"))
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let json = object(file), let record = json["record"] as? [String: Any],
                      let identity = record["identity"] as? [String: Any],
                      let rows = record["rows"] as? [String: Any] else { return nil }
                let metadata = (rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any]
                if metadata?["blank"] as? Bool == true { return nil }
                let label = (rows["title"] as? [String: Any])?["val"] as? String
                let updated = date(metadata?["lastPromptAt"]) ?? modified(file) ?? date(identity["createdAt"])
                guard let updated else { return nil }
                return .init(id: file.deletingPathExtension().lastPathComponent, title: title(label),
                             path: file.path, updatedAt: updated, status: .unknown)
            }
    }

    private static func gemini(_ root: URL) -> [LocalProviderSession] {
        // Gemini uses tmp/<project>/chats/session-*.json. Never walk the user's home or project trees.
        let projects = children(root.appendingPathComponent("tmp")).filter(isDirectory)
        return projects.flatMap { children($0.appendingPathComponent("chats")) }
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
            .prefix(3000).compactMap { file in
                guard let json = object(file), let id = json["sessionId"] as? String, !id.isEmpty,
                      let updated = date(json["lastUpdated"]) ?? modified(file) else { return nil }
                // Do not derive a title from user/assistant messages.
                let label = json["title"] as? String ?? json["summary"] as? String
                return .init(id: id, title: title(label), path: file.path, updatedAt: updated, status: .unknown)
            }
    }

    private static func children(_ directory: URL) -> [URL] {
        guard isDirectory(directory) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return Array(files.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false }
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }.prefix(3000))
    }

    private static func isDirectory(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func object(_ file: URL) -> [String: Any]? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: file), data.count <= 2 * 1024 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func title(_ value: String?) -> String {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "未命名会话" : String(cleaned.prefix(500))
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let timestamp = number.doubleValue
            guard timestamp.isFinite, timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp)
        }
        guard var text = value as? String else { return nil }
        // SQLite/Go stores a space between the date and time; ISO8601 requires T.
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text.replaceSubrange(text.index(text.startIndex, offsetBy: 10)...text.index(text.startIndex, offsetBy: 10), with: "T")
        }
        return ISO8601.parse(text)
    }
}
