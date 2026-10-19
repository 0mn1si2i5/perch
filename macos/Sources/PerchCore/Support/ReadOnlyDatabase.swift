import Foundation
import SQLite3

/// A read-only SQLite connection to a client's database. Never writes, and never creates -wal or -shm files.
final class ReadOnlyDatabase {
    private var db: OpaquePointer?

    init?(_ path: String) {
        // A WAL database whose -wal file is gone has no writer open. A read-only connection cannot create
        // the -wal and -shm files and fails with "unable to open database file", so read it as immutable.
        let query = Self.isWAL(path) && !FileManager.default.fileExists(atPath: path + "-wal") ? "?immutable=1" : "?mode=ro"
        let uri = URL(fileURLWithPath: path).absoluteString + query
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return nil
        }
        sqlite3_busy_timeout(db, 150)
    }

    deinit { sqlite3_close(db) }

    /// Bytes 18 and 19 of the header are 2 for WAL mode.
    static func isWAL(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2
    }

    func rows(_ sql: String, text: String? = nil) -> [[String?]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        if let text {
            _ = text.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { return nil }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                guard let bytes = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: bytes)
            })
        }
    }
}
