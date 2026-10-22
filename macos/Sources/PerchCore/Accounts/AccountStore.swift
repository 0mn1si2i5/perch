import Foundation

public enum AccountError: LocalizedError, Equatable {
    case emptyName, notFound, notLoaded, alreadyAdded, dataInUse, runningUnknown
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "名称不能为空"
        case .notFound: return "找不到这个账号"
        case .notLoaded: return "账号列表尚未成功读取，已停止写入以免覆盖"
        case .alreadyAdded: return "已经有账号在使用这份数据"
        case .dataInUse: return "客户端仍在使用这个数据目录，请先退出它再移除并回收。"
        case .runningUnknown: return "无法确认客户端是否还在使用这个数据目录，已取消移除。"
        }
    }
}

struct AccountFile: Codable {
    var version = 1
    var accounts: [Account]
}

/// Account slots stored in `<root>/accounts.json` (mode 0600).
public final class AccountStore {
    public let root: URL
    /// Home directory used to find clients' default data; injectable for tests.
    public let home: String
    /// Running processes, checked before data goes to the Trash; nil means they could not be read. Injectable for tests.
    public let processes: () -> [RunningProcess]?
    public private(set) var accounts: [Account] = []
    /// Set once `load()` succeeds; `save()` refuses to run before that so a failed read never overwrites accounts.json.
    private var loaded = false
    public var fileURL: URL { root.appendingPathComponent("accounts.json") }

    public init(root: URL, home: String = NSHomeDirectory(),
                processes: @escaping () -> [RunningProcess]? = { ProcessMatcher.snapshot() }) {
        self.root = root
        self.home = home
        self.processes = processes
    }

    public static func standard() -> AccountStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AccountStore(root: support.appendingPathComponent("Perch"))
    }

    public func load() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let (data, removed) = try Self.separatingRemoved(Data(contentsOf: fileURL))
            let file = try Self.decoder.decode(AccountFile.self, from: data)
            accounts = file.accounts
            // Back up before rewriting accounts.json, so a failed backup leaves the old file as it was.
            if !removed.isEmpty { try backUpRemoved(removed) }
            loaded = true
            if !removed.isEmpty { try save() }
        } else {
            accounts = []
            loaded = true
            try save()
        }
    }

    /// API providers and custom clients from earlier versions, kept unchanged. Their Keychain keys are not touched.
    public var removedAccountsURL: URL { root.appendingPathComponent("removed-accounts.json") }

    /// Splits accounts of removed types (and the website launch kind only custom clients used) out of accounts.json.
    static func separatingRemoved(_ data: Data) throws -> (kept: Data, removed: [[String: Any]]) {
        guard var file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = file["accounts"] as? [[String: Any]] else { return (data, []) }
        func isRemoved(_ row: [String: Any]) -> Bool {
            AppKind.removedRawValues.contains(row["appId"] as? String ?? "") || row["apiProvider"] != nil
                || (row["localProvider"] as? [String: Any])?["kind"] as? String == "website"
        }
        let removed = rows.filter(isRemoved)
        guard !removed.isEmpty else { return (data, []) }
        file["accounts"] = rows.filter { !isRemoved($0) }
        return (try JSONSerialization.data(withJSONObject: file), removed)
    }

    private func backUpRemoved(_ removed: [[String: Any]]) throws {
        var rows: [[String: Any]] = []
        if let data = try? Data(contentsOf: removedAccountsURL),
           let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previous = file["accounts"] as? [[String: Any]] { rows = previous }
        let known = Set(rows.compactMap { $0["id"] as? String })
        rows += removed.filter { !known.contains($0["id"] as? String ?? "") }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "accounts": rows],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: removedAccountsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: removedAccountsURL.path)
    }

    public func create(name: String, app: AppKind, now: Date = Date()) throws -> Account {
        guard AppKind.desktopClients.contains(app) else { throw ProviderError.invalid("请用“自动获取可用供应商”添加这个客户端") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyName }
        let id = UUID().uuidString.lowercased()
        let profile = root.appendingPathComponent("Profiles/\(app.displayName)/\(Self.folderName(trimmed))-\(id.prefix(8))")
        let session = app == .codex ? profile.appendingPathComponent("codex-home") : profile
        let fm = FileManager.default
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
        let account = Account(id: id, name: trimmed, app: app, profilePath: profile.path,
                              sessionRoot: session.path, createdAt: now, lastLaunchedAt: nil)
        accounts.append(account)
        try save()
        return account
    }

    public func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyName }
        try update(id) { $0.name = trimmed }
    }

    public func relocate(id: String, profilePath: String) throws {
        if accounts.contains(where: { $0.id != id && $0.profilePath == profilePath }) { throw AccountError.alreadyAdded }
        try update(id) {
            $0.profilePath = profilePath
            $0.sessionRoot = $0.app.sessionRoot(forProfile: profilePath, home: home)
        }
    }

    /// Points an account at its client's default data (the instance opened from the Dock). Nothing is moved.
    public func useDefaultData(id: String) throws {
        guard let account = accounts.first(where: { $0.id == id }) else { throw AccountError.notFound }
        let path = account.app.defaultProfilePath(home: home)
        if accounts.contains(where: { $0.id != id && $0.profilePath == path }) { throw AccountError.alreadyAdded }
        try relocate(id: id, profilePath: path)
    }

    /// Adds an account for a client's default data without creating any directory.
    @discardableResult
    public func addDefault(app: AppKind, name: String, now: Date = Date()) throws -> Account {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyName }
        let path = app.defaultProfilePath(home: home)
        guard !accounts.contains(where: { $0.profilePath == path }) else { throw AccountError.alreadyAdded }
        let account = Account(id: UUID().uuidString.lowercased(), name: trimmed, app: app, profilePath: path,
                              sessionRoot: app.defaultSessionRoot(home: home), createdAt: now, lastLaunchedAt: nil)
        accounts.append(account)
        try save()
        return account
    }

    public func isDefaultData(_ account: Account) -> Bool {
        account.profilePath == account.app.defaultProfilePath(home: home)
    }

    /// Clients that have been used normally (their default data exists) but no account points at that data.
    public func unclaimedDefaults() -> [AppKind] {
        AppKind.desktopClients.filter { app in
            let path = app.defaultProfilePath(home: home)
            return FileManager.default.fileExists(atPath: path) && !accounts.contains { $0.profilePath == path }
        }
    }

    /// Local provider accounts reference existing data. They never create, move or delete client data.
    @discardableResult
    public func importLocal(_ candidate: LocalProviderCandidate) throws -> Account {
        guard loaded else { throw AccountError.notLoaded }
        guard !AppKind.desktopClients.contains(candidate.app) else { throw ProviderError.invalid("客户端配置与账号类型不一致") }
        guard !accounts.contains(where: { $0.app == candidate.app && $0.profilePath == candidate.profilePath }) else { throw AccountError.alreadyAdded }
        try candidate.configuration.validate()
        let account = Account(id: UUID().uuidString.lowercased(), name: candidate.name, app: candidate.app,
                              profilePath: candidate.profilePath, sessionRoot: candidate.profilePath,
                              createdAt: Date(), lastLaunchedAt: nil, localProvider: candidate.configuration)
        accounts.append(account)
        do { try save() } catch { accounts.removeLast(); throw error }
        return account
    }

    /// Points a local provider at a new launch location. Name, order and the referenced data stay as they are.
    public func updateLocalLaunch(id: String, configuration: LocalProviderConfiguration) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        guard accounts[index].localProvider != nil else { throw ProviderError.invalid("不是本机供应商") }
        try configuration.validate()
        let previous = accounts[index]
        accounts[index].localProvider = configuration
        do { try save() } catch { accounts[index] = previous; throw error }
    }

    public func markLaunched(id: String, at date: Date) throws {
        try update(id) { $0.lastLaunchedAt = date }
    }

    /// Removes the slot. Data goes to the Trash only when asked; it is never deleted permanently.
    /// Data a client still uses (or might use, when processes cannot be read) is refused and the account kept.
    public func delete(id: String, moveDataToTrash: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        // The client's own default data is what the Dock instance uses; deleting the account only forgets it.
        let trash = moveDataToTrash && accounts[index].localProvider == nil && !isDefaultData(accounts[index])
            && FileManager.default.fileExists(atPath: accounts[index].profilePath)
        if trash {
            guard let running = processes() else { throw AccountError.runningUnknown }
            if ProcessMatcher.owner(of: accounts[index].profilePath, in: running, home: home) != nil { throw AccountError.dataInUse }
        }
        let account = accounts.remove(at: index)
        do { try save() } catch { accounts.insert(account, at: index); throw error }
        if trash {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: account.profilePath), resultingItemURL: nil)
        }
    }

    /// Moves an account to just before another one (or to the end when `target` is nil). Order is saved.
    public func move(id: String, before target: String?) throws {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        guard id != target else { return }
        let account = accounts.remove(at: from)
        if let target {
            guard let to = accounts.firstIndex(where: { $0.id == target }) else {
                accounts.insert(account, at: from); throw AccountError.notFound
            }
            accounts.insert(account, at: to)
        } else {
            accounts.append(account)
        }
        try save()
    }

    private func update(_ id: String, _ change: (inout Account) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        change(&accounts[index])
        try save()
    }

    func save() throws {
        guard loaded else { throw AccountError.notLoaded }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let data = try Self.encoder.encode(AccountFile(accounts: accounts))
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func folderName(_ name: String) -> String {
        let replaced = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        let trimmed = String(replaced.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "account" : String(trimmed.prefix(40))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无法识别的日期 \(text)"))
            }
            return date
        }
        return decoder
    }()
}
