import Darwin
import Foundation

/// Read-only aggregate summary exported by omni-insights (`<root>/insights/summary.json`).
public struct InsightsSummary: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let days: Int
        public let start: String?
        public let end: String?
        public let startDate: Date?
        public let endDate: Date?

        public init(days: Int, start: String? = nil, end: String? = nil,
                    startDate: Date? = nil, endDate: Date? = nil) {
            self.days = days
            self.start = start
            self.end = end
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    public struct Totals: Equatable, Sendable {
        public let sessions: Int
        public let subagents: Int?
        public let activeDays: Int?
        public let cacheHitRate: Double?
        public let errorRate: Double?

        public init(sessions: Int, subagents: Int? = nil, activeDays: Int? = nil,
                    cacheHitRate: Double? = nil, errorRate: Double? = nil) {
            self.sessions = sessions
            self.subagents = subagents
            self.activeDays = activeDays
            self.cacheHitRate = cacheHitRate
            self.errorRate = errorRate
        }
    }

    public struct Agent: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let role: String?
        public let sessions: Int
        public let subagents: Int?
        public let cacheHitRate: Double?
        public let errorRate: Double?

        public init(id: String, name: String, role: String? = nil, sessions: Int,
                    subagents: Int? = nil, cacheHitRate: Double? = nil, errorRate: Double? = nil) {
            self.id = id
            self.name = name
            self.role = role
            self.sessions = sessions
            self.subagents = subagents
            self.cacheHitRate = cacheHitRate
            self.errorRate = errorRate
        }
    }

    public struct Delta: Equatable, Sendable {
        public let comparedTo: String?
        public let comparedToDate: Date?
        public let sessions: Int?
        public let cacheHitRate: Double?
        public let errorRate: Double?

        public init(comparedTo: String? = nil, comparedToDate: Date? = nil,
                    sessions: Int? = nil, cacheHitRate: Double? = nil, errorRate: Double? = nil) {
            self.comparedTo = comparedTo
            self.comparedToDate = comparedToDate
            self.sessions = sessions
            self.cacheHitRate = cacheHitRate
            self.errorRate = errorRate
        }
    }

    public static let supportedVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let window: Window
    public let reportPath: String?
    public let totals: Totals
    public let agents: [Agent]
    public let delta: Delta?

    public init(version: Int, generatedAt: Date, window: Window, reportPath: String?,
                totals: Totals, agents: [Agent], delta: Delta?) {
        self.version = version
        self.generatedAt = generatedAt
        self.window = window
        self.reportPath = reportPath
        self.totals = totals
        self.agents = agents
        self.delta = delta
    }

    public static func decode(_ data: Data) -> InsightsSummary? {
        guard let raw = try? JSONDecoder().decode(RawSummary.self, from: data),
              raw.version == supportedVersion,
              raw.window.days >= 0,
              raw.totals.sessions >= 0,
              let generatedAt = parseDate(raw.generatedAt) else {
            return nil
        }

        let trimmedReport = raw.reportPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportPath = (trimmedReport?.isEmpty == false) ? trimmedReport : nil
        let start = Self.nonEmpty(raw.window.start)
        let end = Self.nonEmpty(raw.window.end)
        let window = Window(
            days: raw.window.days,
            start: start,
            end: end,
            startDate: start.flatMap(parseDate),
            endDate: end.flatMap(parseDate)
        )
        let totals = Totals(
            sessions: raw.totals.sessions,
            subagents: raw.totals.subagents,
            activeDays: raw.totals.activeDays,
            cacheHitRate: finite(raw.totals.cacheHitRate),
            errorRate: finite(raw.totals.errorRate)
        )
        let agents: [Agent] = (raw.agents ?? []).compactMap { item in
            guard !item.id.isEmpty, !item.name.isEmpty, item.sessions >= 0 else { return nil }
            return Agent(
                id: item.id,
                name: item.name,
                role: Self.nonEmpty(item.role),
                sessions: item.sessions,
                subagents: item.subagents,
                cacheHitRate: finite(item.cacheHitRate),
                errorRate: finite(item.errorRate)
            )
        }
        let delta: Delta? = raw.delta.map { item in
            let compared = Self.nonEmpty(item.comparedTo)
            return Delta(
                comparedTo: compared,
                comparedToDate: compared.flatMap(parseDate),
                sessions: item.sessions,
                cacheHitRate: finite(item.cacheHitRate),
                errorRate: finite(item.errorRate)
            )
        }
        return InsightsSummary(
            version: raw.version,
            generatedAt: generatedAt,
            window: window,
            reportPath: reportPath,
            totals: totals,
            agents: agents,
            delta: delta
        )
    }

    /// Parses ISO8601 timestamps (with or without fractional seconds/microseconds and timezone offset)
    /// as well as date-only `YYYY-MM-DD` strings.
    public static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: trimmed) { return date }

        if trimmed.count == 10 {
            let dayOnly = DateFormatter()
            dayOnly.locale = Locale(identifier: "en_US_POSIX")
            dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dayOnly.dateFormat = "yyyy-MM-dd"
            if let date = dayOnly.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Validates `reportPath`: expands leading `~/`, resolves all symlinks via `realpath`,
    /// requires the canonical target to be a regular `.html`/`.htm` file strictly inside `home`.
    public func validatedReportURL(home: String = NSHomeDirectory(),
                                   fileManager: FileManager = .default) -> URL? {
        Self.validateReportPath(reportPath, home: home, fileManager: fileManager)
    }

    public static func validateReportPath(_ rawPath: String?,
                                          home: String = NSHomeDirectory(),
                                          fileManager: FileManager = .default) -> URL? {
        guard let raw = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let expanded: String
        if raw == "~" {
            expanded = home
        } else if raw.hasPrefix("~/") {
            let base = home.hasSuffix("/") ? String(home.dropLast()) : home
            expanded = base + "/" + raw.dropFirst(2)
        } else if raw.hasPrefix("~") {
            // Reject `~otheruser/...` paths outside the current user's home.
            return nil
        } else {
            expanded = raw
        }

        guard expanded.hasPrefix("/") else { return nil }
        guard let canonicalHome = canonicalPath(home),
              let canonicalTarget = canonicalPath(expanded) else { return nil }

        let homePrefix = canonicalHome == "/" ? "/" : canonicalHome + "/"
        guard canonicalTarget.hasPrefix(homePrefix) else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalTarget, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }

        let resolvedURL = URL(fileURLWithPath: canonicalTarget)
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }

        let ext = resolvedURL.pathExtension.lowercased()
        guard ext == "html" || ext == "htm" else { return nil }
        return resolvedURL
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private struct RawSummary: Decodable {
        let version: Int
        let generatedAt: String
        let window: RawWindow
        let reportPath: String?
        let totals: RawTotals
        let agents: [RawAgent]?
        let delta: RawDelta?
    }

    private struct RawWindow: Decodable {
        let days: Int
        let start: String?
        let end: String?
    }

    private struct RawTotals: Decodable {
        let sessions: Int
        let subagents: Int?
        let activeDays: Int?
        let cacheHitRate: Double?
        let errorRate: Double?
    }

    private struct RawAgent: Decodable {
        let id: String
        let name: String
        let role: String?
        let sessions: Int
        let subagents: Int?
        let cacheHitRate: Double?
        let errorRate: Double?
    }

    private struct RawDelta: Decodable {
        let comparedTo: String?
        let sessions: Int?
        let cacheHitRate: Double?
        let errorRate: Double?
    }
}

/// Passive, bounded (256 KB), mtime+size-cached reader for `<root>/insights/summary.json`.
public final class InsightsSummaryReader {
    public static let maxBytes: UInt64 = 256 * 1024

    public let fileURL: URL
    private let lock = NSLock()
    private var cachedStamp: Stamp?
    private var cachedSummary: InsightsSummary?
    /// Exposed for unit tests to verify cache hits skip disk reads.
    public private(set) var readCount: Int = 0

    private struct Stamp: Equatable {
        let modifiedAt: Date
        let fileSize: UInt64
    }

    public init(root: URL) {
        self.fileURL = root.appendingPathComponent("insights/summary.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() -> InsightsSummary? {
        lock.lock()
        defer { lock.unlock() }

        let probe = URL(fileURLWithPath: fileURL.path)
        guard let values = try? probe.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            cachedStamp = nil
            cachedSummary = nil
            return nil
        }

        let byteCount = UInt64(fileSize)
        guard byteCount <= Self.maxBytes else {
            cachedStamp = nil
            cachedSummary = nil
            return nil
        }

        let stamp = Stamp(modifiedAt: modifiedAt, fileSize: byteCount)
        if cachedStamp == stamp {
            return cachedSummary
        }

        readCount += 1
        guard let data = try? Data(contentsOf: probe),
              UInt64(data.count) <= Self.maxBytes else {
            cachedStamp = nil
            cachedSummary = nil
            return nil
        }

        let parsed = InsightsSummary.decode(data)
        cachedStamp = stamp
        cachedSummary = parsed
        return parsed
    }
}
