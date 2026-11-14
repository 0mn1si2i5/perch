import Foundation
import Darwin

/// One service feeds the existing DeepSeek account card. Per-account gates also protect against actor reentrancy.
public actor DshService {
    private final class Entry {
        let gate = DshGate()
        var scope = ""
        var connection: DshConnection?
        var authorization: DshAuthorization?
        var instance: String?
        var snapshot: DshSnapshot?
        var official: ProviderUsage?
        var officialError: String?
        var nextOfficial = Date.distantPast
        let api = DshApiBalance()
        func clear() {
            connection = nil; authorization = nil; instance = nil; snapshot = nil
            official = nil; officialError = nil; nextOfficial = .distantPast; api.clear()
        }
    }

    private let root: URL
    private let executable: URL?
    private let credentials: DshAuthorizationStorage
    private let connectionFactory: (DshAuthorization) throws -> DshConnection
    private let lockRoot: URL?
    private var entries: [String: Entry] = [:]

    public init(root: URL, executable: URL? = Bundle.main.executableURL) {
        self.root = root; self.executable = executable
        credentials = DshAuthorizationStore()
        connectionFactory = { try DshConnection(authorization: $0) }
        lockRoot = nil
    }

    /// Test injection does not touch the login Keychain or the production host lock directory.
    init(root: URL, executable: URL? = nil, credentials: DshAuthorizationStorage,
         connectionFactory: @escaping (DshAuthorization) throws -> DshConnection) {
        self.root = root; self.executable = executable; self.credentials = credentials
        self.connectionFactory = connectionFactory; lockRoot = root.appendingPathComponent("test-locks")
    }

    private func state(_ account: Account) throws -> DshState {
        guard account.app == .deepseek, account.dshWeb != nil else { throw DshError.invalid("这个账号没有配置 dsh Web。") }
        return try DshState(root: root, key: DshState.key(for: account), lockRoot: lockRoot)
    }

    private func withEntry<T>(_ account: Account, operation: (Entry) async throws -> T) async throws -> T {
        let entry = entries[account.id] ?? Entry()
        entries[account.id] = entry
        await entry.gate.acquire()
        do {
            let state = try state(account)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let config = try encoder.encode(account.dshWeb)
            let scope = state.credentialKey + String(decoding: config, as: UTF8.self)
            if entry.scope != scope { entry.clear(); entry.scope = scope }
            let result = try await operation(entry)
            await entry.gate.release()
            return result
        } catch {
            await entry.gate.release()
            throw error
        }
    }

    private func connection(_ entry: Entry, account: Account, interactive: Bool = false) throws -> DshConnection {
        let state = try state(account)
        guard let runtime = try state.read(), runtime.phase == "ready" else {
            throw DshError.invalid((try? state.read())?.detail.nonEmpty ?? "dsh 尚未连接或服务已停止。")
        }
        if account.dshWeb?.mode != .external && !DshState.childAlive(runtime) {
            throw DshError.invalid("dsh 服务已停止，请重新启动。")
        }
        guard let authorization = try credentials.read(state.credentialKey, interactive: interactive) else {
            throw DshError.invalid("没有可恢复的 dsh 授权，请重新连接。")
        }
        if entry.authorization != authorization || entry.instance != runtime.instance || entry.connection == nil {
            // Neither a replacement instance nor a different home may inherit the previous wallet or task state.
            entry.clear()
            entry.connection = try connectionFactory(authorization)
            entry.authorization = authorization
            entry.instance = runtime.instance
        }
        return entry.connection!
    }

    public func connect(account: Account, url: String) async throws {
        try await withEntry(account) { entry in
            let validated = try DshConnection.validateURL(url)
            let state = try state(account)
            let previous = account.dshWeb?.mode == .external ? nil : try state.read()
            if account.dshWeb?.mode != .external {
                guard let previous, DshState.childAlive(previous), !previous.origin.isEmpty,
                      previous.origin == DshState.origin(validated) else {
                    throw DshError.invalid("受管账号只能重新授权自身运行中的 Web 服务；其他实例请使用“连接已有实例”。")
                }
            }
            let connection = try connectionFactory(.init(url: validated.absoluteString))
            try await connection.authenticate()
            let sessions = try await connection.sessions()
            try state.prepare()
            var runtime = previous
            if runtime == nil { runtime = DshRuntime(phase: "ready") }
            runtime!.phase = "ready"; runtime!.detail = ""; runtime!.origin = DshState.origin(validated)
            try credentials.write(connection.authorization, key: state.credentialKey, interactive: true)
            try state.write(runtime!)
            entry.clear()
            entry.connection = connection; entry.authorization = connection.authorization
            entry.instance = runtime!.instance
            entry.snapshot = .init(sessions: sessions, running: true, detail: "dsh 本机 Web", observedAt: Date())
        }
    }

    public func ensure(account: Account) async throws -> URL {
        try await withEntry(account) { entry in
            let state = try state(account)
            try state.prepare()
            var runtime = try state.read()
            if account.dshWeb?.mode != .external {
                if !DshState.childAlive(runtime) && !state.hostAlive() {
                    let launch = try DshInstallation.resolve(account: account)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: launch.home, isDirectory: &isDirectory) {
                        guard isDirectory.boolValue else { throw DshError.invalid("DSH_HOME 不是目录。") }
                    } else {
                        try DshState.privateDirectory(URL(fileURLWithPath: launch.home))
                    }
                    try DshState.write(launch, to: state.launchURL)
                    // Explicit launch may need Keychain consent after an ad-hoc signed app update.
                    // Preflight in the user-requested operation; automatic polls never enable interaction.
                    let previousAuthorization = try credentials.read(state.credentialKey, interactive: true)
                    try credentials.write(previousAuthorization ?? .init(url: ""), key: state.credentialKey, interactive: true)
                    guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw DshError.invalid("找不到 Perch 后台宿主，请重新构建完整应用。")
                    }
                    let host = Process()
                    host.executableURL = executable
                    host.arguments = ["--dsh-host", root.path, state.key]
                    host.standardInput = FileHandle.nullDevice
                    host.standardOutput = FileHandle.nullDevice
                    host.standardError = FileHandle.nullDevice
                    do { try host.run() } catch { throw DshError.invalid("无法启动 dsh 后台宿主。") }
                    let deadline = Date().addingTimeInterval(70)
                    while Date() < deadline {
                        runtime = try state.read()
                        if runtime?.hostPID == host.processIdentifier && runtime?.phase == "error" {
                            throw DshError.invalid(runtime?.detail.nonEmpty ?? "dsh 启动失败。")
                        }
                        if runtime?.phase == "ready" && DshState.childAlive(runtime) { break }
                        if !host.isRunning && !state.hostAlive() {
                            throw DshError.invalid("dsh 后台宿主未能启动，请检查安装配置。")
                        }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    // Foundation Process does not kill its child on deinit. Only the independent host owns node.
                } else if state.hostAlive() && runtime?.phase != "ready" {
                    let deadline = Date().addingTimeInterval(70)
                    while Date() < deadline && state.hostAlive() {
                        runtime = try state.read()
                        if runtime?.phase == "ready" || runtime?.phase == "error" { break }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
            }
            let current = try connection(entry, account: account, interactive: true)
            let sessions = try await current.sessions()
            entry.snapshot = .init(sessions: sessions, running: true, detail: "dsh 本机 Web", observedAt: Date())
            return try DshConnection.validateURL(current.authorization.url)
        }
    }

    public func read(account: Account) async -> DshSnapshot {
        do {
            return try await withEntry(account) { entry in
                do {
                    let connection = try connection(entry, account: account)
                    let sessions = try await connection.sessions()
                    let state = try state(account)
                    let detail = account.dshWeb?.mode != .external && !state.hostAlive()
                        ? "dsh 宿主已退出，服务仍在运行；停止后可重启。" : "dsh 本机 Web"
                    let snapshot = DshSnapshot(sessions: sessions, running: true, detail: detail, observedAt: Date())
                    entry.snapshot = snapshot
                    return snapshot
                } catch {
                    var previous = entry.snapshot ?? DshSnapshot()
                    previous.running = false; previous.cached = entry.snapshot != nil
                    previous.detail = Self.failure(error)
                    previous.sessions = previous.sessions.map { $0.changingStatus(.unknown, label: "状态未知") }
                    return previous
                }
            }
        } catch { return DshSnapshot(detail: Self.failure(error)) }
    }

    public func balances(account: Account, manual: Bool = false) async -> DshBalances {
        do {
            return try await withEntry(account) { entry in
                let connection: DshConnection
                do { connection = try self.connection(entry, account: account) }
                catch {
                    entry.api.clear()
                    return DshBalances(official: entry.official, officialError: Self.failure(error), apiError: "dsh 未连接，无法确认当前 API 凭据。")
                }
                let route: DshBilling
                do { route = try await connection.billingRoute() }
                catch { entry.api.clear(); route = DshBilling(detail: "模型计费通道查询失败") }
                if manual || Date() >= entry.nextOfficial {
                    entry.nextOfficial = Date().addingTimeInterval(30)
                    do {
                        entry.official = try await connection.officialBalance(billing: route.detail)
                        entry.officialError = nil
                    } catch { entry.officialError = "官方钱包查询失败；如有上次余额，显示其原记录时间。" }
                }
                let home = account.dshWeb?.mode == .external ? account.dshWeb?.balanceHome ?? "" : account.profilePath
                var api = await entry.api.read(route: route, home: home, manual: manual)
                if api.usage != nil {
                    do {
                        if try await connection.billingRoute() != route {
                            entry.api.clear(); api = .init(error: "模型或凭据来源已变更，请刷新余额。")
                        }
                    } catch {
                        entry.api.clear(); api = .init(error: "无法确认当前计费通道，已清除 API 余额缓存。")
                    }
                }
                return DshBalances(official: entry.official, officialError: entry.officialError,
                                   api: api.usage, apiError: api.error)
            }
        } catch { return DshBalances(officialError: Self.failure(error), apiError: Self.failure(error)) }
    }

    public func isManagedRunning(account: Account) -> Bool {
        guard account.dshWeb?.mode != .external, let state = try? state(account) else { return false }
        return state.hostAlive() || DshState.childAlive(try? state.read())
    }

    public func stop(account: Account) async throws {
        try await withEntry(account) { entry in
            let state = try state(account)
            if account.dshWeb?.mode == .external {
                // Disconnecting a browser instance never owns or signals the external process.
                try state.write(.init(phase: "disconnected", detail: "已断开 dsh 连接。"))
                try credentials.remove(state.credentialKey)
            } else if state.hostAlive() {
                guard let runtime = try state.read(), runtime.hostPID > 0 else {
                    throw DshError.invalid("dsh 正在启动，请稍后重试停止。")
                }
                try state.requestStop(runtime)
                let deadline = Date().addingTimeInterval(15)
                while state.hostAlive() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
                guard !state.hostAlive() else { throw DshError.invalid("dsh 尚未停止，请稍后重试。") }
            } else if let runtime = try state.read(), DshState.childAlive(runtime) {
                // The orphan is no longer our child, so do not signal a PID/process group that can be reused.
                throw DshError.invalid("dsh 宿主已退出但服务仍在运行。请在系统活动监视器确认并停止原 dsh 服务，再从 Perch 启动。")
            }
            entry.clear()
        }
    }

    private static func failure(_ error: Error) -> String {
        (error as? DshError)?.localizedDescription ?? "dsh 操作失败，请检查本机服务、数据目录和钥匙串权限。"
    }
}

private actor DshGate {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { held = false }
        else { waiting.removeFirst().resume() }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
