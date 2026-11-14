import Foundation
import CoreFoundation

/// A private cookie jar for one loopback Web instance. Raw responses are never persisted or logged.
public final class DshConnection: @unchecked Sendable {
    private let http: URLSession
    private let origin: URL
    private let lock = NSLock()
    private var storedAuthorization: DshAuthorization
    private var outcomes: [String: (sequence: Int64, status: TaskStatus?)] = [:]
    public var authorization: DshAuthorization { lock.withLock { storedAuthorization } }

    public init(authorization: DshAuthorization, configuration: URLSessionConfiguration = .ephemeral) throws {
        let url = try Self.validateURL(authorization.url)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil; components.path = "/"
        origin = components.url!
        storedAuthorization = authorization
        let config = configuration.copy() as! URLSessionConfiguration
        // Loopback RPC must not follow a system HTTP proxy or reuse the browser's cookies.
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        http = PrivateHTTP.session(timeout: 10, resourceTimeout: 20, configuration: config)
    }

    deinit { http.invalidateAndCancel() }

    public static func validateURL(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192,
              let components = URLComponents(string: value), components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased(), isLoopback(host),
              let items = components.queryItems, items.count == 1, items[0].name == "token",
              let token = items[0].value, !token.isEmpty,
              let url = components.url else {
            throw DshError.invalid("请粘贴 dsh 启动时输出的本机 http:// 回环授权 URL（包含 token）。")
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil
        }
    }

    public func authenticate() async throws {
        let current = authorization
        var request = URLRequest(url: try Self.validateURL(current.url), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        let (_, response) = try await send(request)
        guard [200, 303].contains(response.statusCode) else {
            throw DshError.invalid("dsh 授权已失效，请重新连接并粘贴当前启动的授权 URL。")
        }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: origin).filter {
            ($0.expiresDate ?? .distantFuture) > Date() && !$0.isSecure && ($0.path == "/" || $0.path.isEmpty)
        }
        let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        guard !cookie.isEmpty else { throw DshError.invalid("dsh 未返回认证 cookie，请复制启动输出中的完整授权 URL。") }
        lock.withLock { storedAuthorization = .init(url: current.url, cookie: cookie) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await http.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else {
                throw DshError.invalid("dsh 响应过大或格式不兼容，请检查版本与连接。")
            }
            return (data, response)
        } catch let error as DshError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession errors can contain the token URL: never expose them to the panel.
            throw DshError.invalid("dsh 本机连接失败或超时，请检查服务或重新连接。")
        }
    }

    private func rpc(_ method: String, args: [String: Any]) async throws -> Any {
        if authorization.cookie.isEmpty { try await authenticate() }
        let id = UUID().uuidString
        var request = URLRequest(url: origin.appendingPathComponent("api/" + method), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization.cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "client-request", "rpcId": id,
            "method": method, "payload": ["args": args]])
        let (data, response) = try await send(request)
        if [401, 403].contains(response.statusCode) { throw DshError.invalid("dsh 连接授权已失效，请重新连接。") }
        guard (200..<300).contains(response.statusCode) else {
            throw DshError.invalid("dsh 接口 \(method) 返回 HTTP \(response.statusCode)，请检查版本与连接。")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "server-response", root["rpcId"] as? String == id,
              let result = root["result"] as? [String: Any], DshJSON.bool(result["ok"]) == true,
              let value = result["value"] else {
            throw DshError.invalid("dsh 接口 \(method) 的响应不兼容，请检查版本与 profile 配置。")
        }
        return value
    }

    private func object(_ method: String, args: [String: Any]) async throws -> [String: Any] {
        guard let object = try await rpc(method, args: args) as? [String: Any] else {
            throw DshError.invalid("dsh 接口 \(method) 的响应格式不兼容。")
        }
        return object
    }

    public func sessions() async throws -> [DshSession] {
        let listed = try Self.parseSessions(await object("session/list", args: ["_request": [:]]))
        var resolved = listed
        // Bound simultaneous history reads; a busy provider must not spawn forty requests at once.
        for start in stride(from: 0, to: listed.count, by: 4) {
            try await withThrowingTaskGroup(of: (Int, DshSession).self) { group in
                for index in start..<min(start + 4, listed.count) {
                    group.addTask { (index, try await self.resolve(listed[index])) }
                }
                for try await (index, session) in group { resolved[index] = session }
            }
        }
        guard resolved != listed else { return listed }
        // A new prompt or active turn wins over a historical completion read from the previous list.
        let current = try Self.parseSessions(await object("session/list", args: ["_request": [:]]))
        let before = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
        let statuses = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let retained = Set(current.map(\.id))
        lock.withLock { outcomes = outcomes.filter { retained.contains($0.key) } }
        return current.map { before[$0.id] == $0 ? statuses[$0.id] ?? $0 : $0 }
    }

    private func resolve(_ session: DshSession) async throws -> DshSession {
        guard session.statusLabel == "空闲" || session.statusLabel == "未运行" else { return session }
        do {
            let baseline = try await object("session/projections", args: ["request": ["sessionId": session.id]])
            guard let sequence = DshJSON.integer(baseline["asOfSeq"]), sequence >= 0 else { return session }
            let values = baseline["values"] as? [String: Any] ?? [:]
            let inbox = values["inbox"] as? [String: Any] ?? [:]
            guard !["next-turn", "next-step"].contains(where: { !(inbox[$0] as? [Any] ?? []).isEmpty }) else { return session }
            var cached = lock.withLock { outcomes[session.id] }
            if cached?.sequence != sequence {
                let page = try await object("session/page", args: ["request": [
                    "address": ["kind": "session", "sessionId": session.id], "throughSeq": sequence, "maxMessages": 1]])
                cached = (sequence, try Self.completionStatus(page))
                lock.withLock { outcomes[session.id] = cached }
            }
            guard let status = cached?.status else { return session }
            return session.changingStatus(status, label: status == .unknown ? "状态未知" : nil)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Older profiles can lack these read-only RPCs. Idle alone is never success evidence.
            return session
        }
    }

    static func completionStatus(_ page: [String: Any]) throws -> TaskStatus? {
        guard let records = page["records"] as? [[String: Any]] else { throw DshError.invalid("dsh 会话结束状态格式不兼容。") }
        for record in records.reversed() where record["type"] as? String == "event" {
            let event = record["event"] as? [String: Any] ?? [:]
            if event["type"] as? String == "turn/start" { return .interrupted }
            guard event["type"] as? String == "turn/end" else { continue }
            let data = event["data"] as? [String: Any] ?? [:]
            let reason = data["reason"] as? [String: Any] ?? [:]
            switch reason["kind"] as? String {
            case "completed": return .completed
            case "aborted", "interrupted", "forked": return .interrupted
            case "error", "blocked", "max-tokens": return .failed
            default: return .unknown
            }
        }
        return nil
    }

    static func parseSessions(_ value: [String: Any]) throws -> [DshSession] {
        guard let items = value["items"] as? [[String: Any]] else { throw DshError.invalid("dsh 会话列表格式不兼容。") }
        var result: [DshSession] = [], seen = Set<String>()
        for item in items {
            if !(item["parentSessionId"] as? String ?? "").isEmpty || item["origin"] as? String == "subagent" { continue }
            let running = DshJSON.bool(item["running"])
            if DshJSON.bool(item["blank"]) == true && running != true { continue }
            guard let id = item["sessionId"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            guard let milliseconds = DshJSON.number(item["updatedAt"]), milliseconds.isFinite,
                  (0...253402300799999).contains(milliseconds) else { throw DshError.invalid("dsh 会话时间格式不兼容。") }
            let projections = item["projections"] as? [String: Any] ?? [:]
            let values = projections["values"] as? [String: Any] ?? [:]
            let title = (values["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = running == true ? "进行中" : running == nil ? "状态未知"
                : DshJSON.bool(item["agentAvailable"]) == true ? "空闲" : "未运行"
            result.append(.init(id: id, title: title.isEmpty ? "未命名会话" : String(title.prefix(140)),
                                workingDirectory: item["cwd"] as? String ?? "", updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                                status: running == true ? .running : .unknown, statusLabel: label))
        }
        return Array(result.sorted {
            if ($0.status == .running) != ($1.status == .running) { return $0.status == .running }
            return $0.updatedAt > $1.updatedAt
        }.prefix(40))
    }

    public func billingRoute() async throws -> DshBilling {
        let catalog = try await object("session/modelCatalog", args: [:])
        let provider = (catalog["default"] as? [String: Any])?["provider"] as? String ?? ""
        if provider == "deepseek-account" { return .init(detail: "默认模型：DeepSeek 官方账户计费", provider: provider) }
        if provider.isEmpty { return .init(detail: "尚未选择默认模型") }
        let settings = try await object("settings/describe", args: [:])
        let config = try Self.providerSettings(settings, provider: provider)
        let reference = config["apiKeyEnv"] as? String ?? ""
        let label = provider == "deepseek-official" ? "DeepSeek API Key" : provider + " API Key"
        if reference.isEmpty { return .init(detail: "默认模型：" + label + " · 凭据状态未知", provider: provider) }
        let credentials = try await object("credentials/describe", args: ["refs": [reference]])
        let credential = credentials[reference] as? [String: Any] ?? [:]
        guard let configured = DshJSON.bool(credential["configured"]) else { throw DshError.invalid("dsh API Key 状态格式不兼容。") }
        return .init(detail: "默认模型：" + label + (configured ? " 已配置" : " 未配置 · 请在 dsh 模型设置中配置"),
                     provider: provider, reference: reference, configured: configured,
                     source: credential["source"] as? String ?? "", baseURL: config["baseURL"] as? String ?? "")
    }

    static func providerSettings(_ settings: [String: Any], provider: String) throws -> [String: Any] {
        guard let namespaces = settings["namespaces"] as? [[String: Any]] else { throw DshError.invalid("dsh 模型设置格式不兼容。") }
        for namespace in namespaces {
            let value = namespace["value"] as? [String: Any] ?? [:]
            if let route = (value["providers"] as? [String: Any])?[provider] as? [String: Any] { return route }
            if provider == "deepseek-official", ["llm-deepseek", "llm-deepseek-api-key"].contains(namespace["ns"] as? String ?? "") { return value }
        }
        return [:]
    }

    public func officialBalance(billing: String) async throws -> ProviderUsage {
        let state = try await object("account/getState", args: [:])
        let status = state["status"] as? String ?? ""
        if status == "signed-out" {
            return .init(metrics: [], summary: billing + "\n官方账户未登录", authenticationVerified: false)
        }
        guard status == "credential-stored" else { throw DshError.invalid("dsh 官方账户状态格式不兼容。") }
        let value = try await rpc("account/getBalance", args: ["client": ["version": "0.2.0", "locale": "zh-CN",
            "timezoneOffsetSeconds": TimeZone.current.secondsFromGMT()]])
        if value is NSNull {
            return .init(metrics: [], summary: billing + "\n官方账户登录已失效，请在 dsh 重新登录", authenticationVerified: false)
        }
        guard let value = value as? [String: Any], value["status"] as? String == "ready",
              let paid = value["value"] as? [[String: Any]], let bonus = value["bonusWallets"] as? [[String: Any]] else {
            throw DshError.invalid("dsh 官方钱包余额格式不兼容。")
        }
        do {
            let metrics = try DeepSeekUsage.wallets(paid, label: "充值余额") + DeepSeekUsage.wallets(bonus, label: "赠送余额")
            return .init(metrics: metrics, summary: billing + "\nDeepSeek 官方登录钱包", authenticationVerified: true)
        } catch { throw DshError.invalid("dsh 官方钱包余额格式不兼容。") }
    }
}

enum DshJSON {
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let value = number(value), value.isFinite, value.rounded() == value,
              value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}
