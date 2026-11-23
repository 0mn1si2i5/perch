import Foundation

/// Last-known provider usage snapshots persisted under `<root>/provider-usage-cache.json` (mode 0600).
/// Stores numeric usage summaries and timestamps only; never stores credentials or conversation content.
public final class ProviderUsageCache {
    struct CacheFile: Codable {
        var version = 1
        var entries: [String: ProviderUsage]
    }

    public let root: URL
    public var fileURL: URL { root.appendingPathComponent("provider-usage-cache.json") }
    private var entries: [String: ProviderUsage] = [:]

    public init(root: URL) { self.root = root }

    @discardableResult
    public func load() -> [String: ProviderUsage] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? AccountStore.decoder.decode(CacheFile.self, from: data) else {
            entries = [:]
            return [:]
        }
        entries = file.entries
        return entries
    }

    public func save(_ usage: ProviderUsage, for accountID: String) {
        entries[accountID] = usage
        write()
    }

    public func remove(accountID: String) {
        guard entries.removeValue(forKey: accountID) != nil else { return }
        write()
    }

    public func prune(keeping validIDs: Set<String>) {
        let filtered = entries.filter { validIDs.contains($0.key) }
        guard filtered.count != entries.count else { return }
        entries = filtered
        write()
    }

    private func write() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let data = try AccountStore.encoder.encode(CacheFile(entries: entries))
            try data.write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {}
    }
}
