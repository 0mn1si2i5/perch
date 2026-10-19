import Foundation

public struct LocalProviderSession: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let path: String
    /// Nil when the provider recorded no usable time (Antigravity writes 0001-01-01 for some rows).
    public let updatedAt: Date?
    public let status: TaskStatus

    public init(id: String, title: String, path: String, updatedAt: Date?, status: TaskStatus) {
        self.id = id; self.title = title; self.path = path
        self.updatedAt = updatedAt; self.status = status
    }
}

/// Local indexes only. Never decrypts credentials or reads compressed conversation bodies.
public enum LocalProviderSessions {
    /// A one-off read without a cache, for diagnostics.
    public static func recent(_ account: Account) -> [LocalProviderSession] {
        LocalProviderSessionReader(account: account).recent()
    }
}

/// Reads one provider account's local session index. Only the newest files are looked at, and a file is parsed
/// again only when its modification time or size changes. Not thread-safe: use one reader from one serial queue.
public final class LocalProviderSessionReader {
    public let app: AppKind
    public let root: String
    /// Files and database reads done so far; tests use it to check the cache.
    private(set) var parsed = 0
    private var files: [String: (signature: Signature, session: LocalProviderSession?)] = [:]
    private var database: (signature: [Signature?], rows: [Row])?

    struct Signature: Equatable { let modified: Date; let size: Int }
    struct Row { let id: String; let title: String; let updatedAt: Date?; let running: Bool }
    private struct File { let url: URL; let signature: Signature }

    static let fileLimit = 60
    /// Files up to this size are parsed whole; larger ones only have their head read.
    static let fullParseLimit = 2 * 1024 * 1024
    static let headLimit = 256 * 1024

    public init(account: Account) {
        app = account.app
        root = account.sessionRoot
    }

    public func recent(now: Date = Date()) -> [LocalProviderSession] {
        guard !root.isEmpty else { return [] }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        let sessions: [LocalProviderSession]
        switch app {
        case .antigravity: sessions = antigravity(base, now: now)
        case .deepseek:
            sessions = read(newest(in: [base.appendingPathComponent("storages/session_projcache/sessions")]) {
                $0.pathExtension == "json"
            }, parse: Self.deepseek)
        case .gemini:
            // Gemini uses tmp/<project>/chats/session-*.json or .jsonl. Never walk the user's home or project trees.
            let chats = Self.children(base.appendingPathComponent("tmp")).filter(Self.isDirectory)
                .map { $0.appendingPathComponent("chats") }
            sessions = read(newest(in: chats) {
                $0.lastPathComponent.hasPrefix("session-") && ["json", "jsonl"].contains($0.pathExtension)
            }, parse: Self.gemini)
        default: return []
        }
        // Rows without a time keep their source order after the dated ones.
        let ordered = sessions.enumerated().sorted { left, right in
            switch (left.element.updatedAt, right.element.updatedAt) {
            case let (l?, r?): return l == r ? left.offset < right.offset : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(30))
    }

    private func read(_ list: [File], parse: (URL, Signature) -> LocalProviderSession?) -> [LocalProviderSession] {
        var kept: [String: (signature: Signature, session: LocalProviderSession?)] = [:]
        let sessions = list.compactMap { file -> LocalProviderSession? in
            let path = file.url.path
            if let cached = files[path], cached.signature == file.signature {
                kept[path] = cached
                return cached.session
            }
            parsed += 1
            let session = parse(file.url, file.signature)
            kept[path] = (file.signature, session)
            return session
        }
        files = kept
        return sessions
    }

    private func newest(in directories: [URL], where accept: (URL) -> Bool) -> [File] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let list = directories.flatMap(Self.children).compactMap { url -> File? in
            guard accept(url), let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
            return File(url: url, signature: Signature(modified: modified, size: size))
        }
        return Array(list.sorted { $0.signature.modified > $1.signature.modified }.prefix(Self.fileLimit))
    }

    // MARK: Antigravity

    private func antigravity(_ base: URL, now: Date) -> [LocalProviderSession] {
        let file = base.appendingPathComponent("conversation_summaries.db").path
        guard FileManager.default.fileExists(atPath: file) else { database = nil; return [] }
        // A writer that keeps the database open changes only the -wal file, so both are compared.
        let signature = [file, file + "-wal"].map(Self.signature)
        if database?.signature != signature {
            parsed += 1
            // A failed read (a writer holding a lock) is not cached, so the next poll reads again.
            if let rows = Self.antigravityRows(file) { database = (signature, rows) }
        }
        return (database?.rows ?? []).map { row in
            var status = TaskStatus.unknown
            if row.running, let updated = row.updatedAt {
                status = now.timeIntervalSince(updated) > 30 * 60 ? .interrupted : .running
            }
            return .init(id: row.id, title: row.title, path: file, updatedAt: row.updatedAt, status: status)
        }
    }

    /// Nil when the database cannot be opened or queried.
    private static func antigravityRows(_ file: String) -> [Row]? {
        // Deliberately omit preview, raw_summary, and the full-text search tables.
        let sql = "SELECT conversation_id, substr(title,1,500), last_modified_time, status FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 60"
        guard let db = ReadOnlyDatabase(file), let rows = db.rows(sql) else { return nil }
        return rows.compactMap { row in
            guard row.count == 4, let id = row[0], !id.isEmpty else { return nil }
            return Row(id: id, title: title(row[1]), updatedAt: date(row[2]), running: row[3] == "CASCADE_RUN_STATUS_RUNNING")
        }
    }

    // MARK: DeepSeek

    private static func deepseek(_ file: URL, _ signature: Signature) -> LocalProviderSession? {
        let id = file.deletingPathExtension().lastPathComponent
        guard signature.size <= fullParseLimit else {
            // The title row is written near the start; the rest is session state.
            guard let head = head(file) else { return nil }
            if head.range(of: #""blank"\s*:\s*true"#, options: .regularExpression) != nil { return nil }
            let label = string(after: #""title"\s*:\s*\{[^{}]*?"val""#, in: head)
            return .init(id: id, title: title(label), path: file.path, updatedAt: signature.modified, status: .unknown)
        }
        guard let json = object(file), let record = json["record"] as? [String: Any],
              record["identity"] is [String: Any], let rows = record["rows"] as? [String: Any] else { return nil }
        let metadata = (rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any]
        if metadata?["blank"] as? Bool == true { return nil }
        let label = (rows["title"] as? [String: Any])?["val"] as? String
        let updated = date(metadata?["lastPromptAt"]) ?? signature.modified
        return .init(id: id, title: title(label), path: file.path, updatedAt: updated, status: .unknown)
    }

    // MARK: Gemini CLI

    private static func gemini(_ file: URL, _ signature: Signature) -> LocalProviderSession? {
        // Do not derive a title from user or assistant messages.
        if file.pathExtension == "jsonl" {
            // The first line is the session header; later `$set` lines update it.
            guard let head = head(file), let line = head.split(separator: "\n", maxSplits: 1).first,
                  let header = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = header["sessionId"] as? String, !id.isEmpty else { return nil }
            var label = header["title"] as? String ?? header["summary"] as? String
            if signature.size <= fullParseLimit, let data = try? Data(contentsOf: file) {
                for line in data.split(separator: UInt8(ascii: "\n")) where line.starts(with: Data(#"{"$set""#.utf8)) {
                    let set = ((try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any])?["$set"] as? [String: Any]
                    label = set?["title"] as? String ?? set?["summary"] as? String ?? label
                }
            }
            return .init(id: id, title: title(label), path: file.path, updatedAt: signature.modified, status: .unknown)
        }
        guard signature.size <= fullParseLimit else {
            // Only the header fields written before the message list are read.
            guard var head = head(file) else { return nil }
            if let messages = head.range(of: #""messages""#) { head = String(head[..<messages.lowerBound]) }
            let id = string(after: #""sessionId""#, in: head) ?? file.deletingPathExtension().lastPathComponent
            let label = string(after: #""title""#, in: head) ?? string(after: #""summary""#, in: head)
            let updated = date(string(after: #""lastUpdated""#, in: head)) ?? signature.modified
            return .init(id: id, title: title(label), path: file.path, updatedAt: updated, status: .unknown)
        }
        guard let json = object(file), let id = json["sessionId"] as? String, !id.isEmpty else { return nil }
        let label = json["title"] as? String ?? json["summary"] as? String
        let updated = date(json["lastUpdated"]) ?? signature.modified
        return .init(id: id, title: title(label), path: file.path, updatedAt: updated, status: .unknown)
    }

    // MARK: Helpers

    private static func children(_ directory: URL) -> [URL] {
        guard isDirectory(directory) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectory(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func signature(_ path: String) -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else { return nil }
        return Signature(modified: modified, size: size)
    }

    private static func object(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file), data.count <= fullParseLimit else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func head(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The JSON string value that follows `key` and a colon, unescaped.
    private static func string(after key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: key + #"\s*:\s*("(?:[^"\\]|\\.)*")"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(text[range].utf8))
    }

    private static func title(_ value: String?) -> String {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "未命名会话" : String(cleaned.prefix(500))
    }

    /// Times before 1970 (such as Go's zero time, 0001-01-01) count as no time.
    static func date(_ value: Any?) -> Date? {
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
        guard let date = ISO8601.parse(text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}
