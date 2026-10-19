import Foundation
import Darwin

/// Uses the selected client's login in place. OAuth refreshes stay in memory.
public final class GoogleProviderUsage {
    private let session: URLSession
    private static let migration = "Gemini CLI 个人账号服务已迁移至 Antigravity；请使用 Antigravity 查询额度和运行模型"

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoProviderRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public static func query(_ account: Account) async throws -> ProviderUsage {
        try await GoogleProviderUsage().fetch(account)
    }

    public func fetch(_ account: Account) async throws -> ProviderUsage {
        guard let config = account.localProvider, config.kind == .terminal else {
            throw ProviderUsageError.unsupported("Gemini 原生应用的额度请在应用的使用限制中查看；不与 CLI 额度混用")
        }
        switch account.app {
        case .antigravity:
            let defaultRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli").standardizedFileURL
            guard URL(fileURLWithPath: account.profilePath).standardizedFileURL == defaultRoot else {
                throw ProviderUsageError.unsupported("Antigravity CLI 额度查询仅支持本机默认登录目录")
            }
            let output = try await Task.detached(priority: .utility) {
                try Self.runUsage(executable: config.target)
            }.value
            try Task.checkCancellation()
            return try Self.parseAntigravity(output)
        case .gemini:
            return try await gemini(root: URL(fileURLWithPath: account.sessionRoot), executable: config.target)
        default: throw ProviderUsageError.unsupported("此客户端没有 Google 额度接口")
        }
    }

    static func parseAntigravity(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try json(data)
        guard object["status"] as? String == "SUCCESS",
              let command = object["command"] as? [String: Any], command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else {
            throw ProviderUsageError.requestFailed("Antigravity 未返回可识别的额度数据，请更新客户端后重试")
        }
        var metrics: [ProviderUsageMetric] = []
        for group in groups.prefix(20) {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets.prefix(20) {
                // The Google quota pool is independent from third-party model allowances.
                guard let id = bucket["id"] as? String, id.hasPrefix("gemini-"),
                      let remaining = fraction(bucket["remaining_fraction"]) else { continue }
                let window = bucket["window"] as? String ?? ""
                let label = window == "weekly" ? "每周" : window == "5h" ? "5 小时" : String((bucket["name"] as? String ?? window).prefix(80))
                metrics.append(.init(label: poolLabel(id) + " · " + label,
                                     remainingPercent: remaining * 100,
                                     resetsAt: (bucket["reset_time"] as? String).flatMap(ISO8601.parse)))
            }
        }
        guard !metrics.isEmpty else { throw ProviderUsageError.unsupported("Antigravity 当前登录没有返回可查询的额度") }
        return .init(metrics: metrics, summary: "Antigravity 实时额度", observedAt: now, authenticationVerified: true)
    }

    /// Argon has its own weekly allowance beside the main Gemini pool; both use `gemini-` bucket ids.
    static func poolLabel(_ bucketID: String) -> String {
        bucketID.localizedCaseInsensitiveContains("argon") ? "Argon" : "Gemini Models"
    }

    static func parseGemini(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try json(data)
        guard let buckets = object["buckets"] as? [[String: Any]] else {
            throw ProviderUsageError.requestFailed("Gemini CLI 未返回可识别的额度数据")
        }
        let metrics: [ProviderUsageMetric] = buckets.prefix(80).compactMap { bucket in
            guard let model = bucket["modelId"] as? String, let remaining = fraction(bucket["remainingFraction"]) else { return nil }
            return .init(label: String(model.prefix(100)), remainingPercent: remaining * 100,
                         resetsAt: (bucket["resetTime"] as? String).flatMap(ISO8601.parse))
        }
        guard !metrics.isEmpty else { throw ProviderUsageError.unsupported("Gemini CLI 当前登录没有返回可查询的额度") }
        return .init(metrics: metrics, summary: "Gemini CLI 实时额度", observedAt: now, authenticationVerified: true)
    }

    private func gemini(root: URL, executable: String) async throws -> ProviderUsage {
        let settings = (try? Data(contentsOf: root.appendingPathComponent("settings.json"))).flatMap { try? Self.json($0) }
        let selectedType = ((settings?["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
        guard selectedType == "oauth-personal" else {
            throw ProviderUsageError.unsupported("此 Gemini CLI 当前未使用 Google 账号登录；API Key 或 Vertex AI 额度请在对应控制台查看")
        }
        let credentials: [String: Any]
        do { credentials = try Self.json(Data(contentsOf: root.appendingPathComponent("oauth_creds.json"))) }
        catch { throw ProviderUsageError.signedOut }
        var token = credentials["access_token"] as? String ?? ""
        let expiry = (credentials["expiry_date"] as? NSNumber)?.doubleValue ?? 0
        if token.isEmpty || expiry < Date().timeIntervalSince1970 * 1000 + 30_000 {
            token = try await refresh(credentials, executable: executable)
        }
        let health: [String: Any] = ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"], "mode": "HEALTH_CHECK"]
        var result = try await post("loadCodeAssist", body: health, token: token)
        if result.status == 401 {
            token = try await refresh(credentials, executable: executable)
            result = try await post("loadCodeAssist", body: health, token: token)
        }
        try Self.check(result.status, data: result.data)
        let loaded = try Self.json(result.data)
        let project = loaded["cloudaicompanionProject"] as? String
            ?? (loaded["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
        guard let project, !project.isEmpty else {
            throw ProviderUsageError.unsupported("当前 Gemini CLI 登录没有可查询额度的项目")
        }
        let quota = try await post("retrieveUserQuota", body: ["project": project], token: token)
        try Self.check(quota.status, data: quota.data)
        return try Self.parseGemini(quota.data)
    }

    private func refresh(_ credentials: [String: Any], executable: String) async throws -> String {
        guard let token = credentials["refresh_token"] as? String, !token.isEmpty else { throw ProviderUsageError.signedOut }
        let client = try Self.installedOAuthClient(executable: executable)
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: token),
                           URLQueryItem(name: "client_id", value: client.id), URLQueryItem(name: "client_secret", value: client.secret)]
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let result = try await send(request)
        if result.status == 400 || result.status == 401 { throw ProviderUsageError.signedOut }
        try Self.check(result.status, data: result.data)
        guard let access = try Self.json(result.data)["access_token"] as? String, !access.isEmpty else {
            throw ProviderUsageError.signedOut
        }
        return access
    }

    /// The installed open-source CLI owns its public OAuth client registration, not Perch.
    /// Read it from that distribution instead of copying registration credentials into this repository.
    static func installedOAuthClient(executable: String) throws -> (id: String, secret: String) {
        let directory = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var bytesRead = 0
        for file in files.filter({ $0.pathExtension == "js" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 48 * 1024 * 1024 else { continue }
            bytesRead += size
            guard bytesRead <= 160 * 1024 * 1024 else { break }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            func constant(_ name: String) -> String? {
                let regex = try! NSRegularExpression(pattern: "(?:var|const)\\s+" + name + "\\s*=\\s*[\"']([^\"'\\r\\n]+)[\"']")
                guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }
            if let id = constant("OAUTH_CLIENT_ID"), let secret = constant("OAUTH_CLIENT_SECRET") { return (id, secret) }
        }
        throw ProviderUsageError.unsupported("无法读取此版本 Gemini CLI 的 OAuth 配置，请更新客户端后重试")
    }

    private func post(_ method: String, body: [String: Any], token: String) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:" + method)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 1024 * 1024 else {
                throw ProviderUsageError.requestFailed("Google 额度服务返回的数据无法识别")
            }
            return (http.statusCode, data)
        } catch is ProviderUsageError { throw ProviderUsageError.requestFailed("Google 额度服务返回的数据无法识别") }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderUsageError.requestFailed("无法连接 Google 额度服务，请稍后重试")
        }
    }

    static func check(_ status: Int, data: Data) throws {
        if (200..<300).contains(status) { return }
        if status == 401 { throw ProviderUsageError.signedOut }
        let error = (try? json(data))?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]] ?? []
        if details.contains(where: { $0["reason"] as? String == "SUBSCRIPTION_REQUIRED" }) {
            throw ProviderUsageError.unsupported(migration)
        }
        throw ProviderUsageError.requestFailed("Google 额度查询失败（HTTP \(status)）")
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let fraction = number.doubleValue
        return fraction.isFinite && (0...1).contains(fraction) ? fraction : nil
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.requestFailed("Google 额度数据无法识别")
        }
        return object
    }

    private static func runUsage(executable: String) throws -> Data {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProviderUsageError.unsupported("找不到 Antigravity CLI，请先安装 agy")
        }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        var env = ProcessInfo.processInfo.environment
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        process.environment = env
        let stdout = UsageOutputBuffer(), stderr = UsageOutputBuffer(), group = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { throw ProviderUsageError.requestFailed("无法启动 Antigravity 额度查询") }
        for (pipe, buffer) in [(output, stdout), (errors, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    if !buffer.append(data), process.isRunning { process.terminate() }
                }
            }
        }
        let timedOut = exited.wait(timeout: .now() + 35) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 2)
        guard !timedOut else { throw ProviderUsageError.requestFailed("Antigravity 额度查询超时，请稍后重试") }
        guard !stdout.overflowed, !stderr.overflowed else { throw ProviderUsageError.requestFailed("Antigravity 额度响应过大") }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.data + stdout.data, encoding: .utf8)?.lowercased() ?? ""
            if message.contains("authentication required") || message.contains("not authenticated") || message.contains("not logged in") {
                throw ProviderUsageError.signedOut
            }
            throw ProviderUsageError.requestFailed("Antigravity 额度查询失败，请在客户端确认登录")
        }
        return stdout.data
    }
}

private final class UsageOutputBuffer {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count + data.count <= 512 * 1024 else { exceeded = true; return false }
        bytes.append(data); return true
    }
}
