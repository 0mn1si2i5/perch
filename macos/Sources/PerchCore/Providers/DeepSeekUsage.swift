import Foundation

/// Reads the same wallet endpoint as DSH Desktop's account provider. No login refresh,
/// credential mutation, inference request, or invented subscription percentage.
public enum DeepSeekUsage {
    enum Credential: Equatable {
        case platform(String)
        case apiKey(String)
    }

    public static func query(_ account: Account) async throws -> ProviderUsage {
        let file = URL(fileURLWithPath: account.profilePath).appendingPathComponent(".credentials.yaml")
        guard account.app == .deepseek, !account.profilePath.isEmpty,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 262_144, let data = try? Data(contentsOf: file) else { throw ProviderUsageError.signedOut }
        return try await query(credentialData: data)
    }

    static func query(credentialData: Data, configuration: URLSessionConfiguration = .ephemeral,
                      now: Date = Date()) async throws -> ProviderUsage {
        let credential = try parseCredential(credentialData)
        let request = makeRequest(credential)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoProviderRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderUsageError.requestFailed("DeepSeek 余额连接失败，请稍后重试")
        }
        guard let http = response as? HTTPURLResponse else { throw invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderUsageError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderUsageError.requestFailed("DeepSeek 余额请求失败（HTTP \(http.statusCode)）")
        }
        return try parseResponse(data, credential: credential, now: now)
    }

    static func makeRequest(_ credential: Credential) -> URLRequest {
        let address: String
        switch credential {
        case .platform: address = "https://platform.deepseek.com/api/v0/users/get_user_summary"
        case .apiKey: address = "https://api.deepseek.com/user/balance"
        }
        var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch credential {
        case .platform(let token): request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
        case .apiKey(let key): request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func parseCredential(_ data: Data) throws -> Credential {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { throw unsupportedCredentials }
        let fields = try credentialFields(text)
        guard fields[["version"]] == "1" else { throw unsupportedCredentials }
        let account = ["records", "deepseek-account-platform/default"]
        if fields[account + ["kind"]] != nil {
            guard fields[account + ["kind"]] == "grant",
                  fields[account + ["payload", "version"]] == "1",
                  fields[account + ["payload", "issuer"]] == "https://platform.deepseek.com",
                  let token = fields[account + ["payload", "token"]], validSecret(token) else { throw unsupportedCredentials }
            return .platform(token)
        }
        if let key = fields[["refs", "DEEPSEEK_API_KEY"]], validSecret(key) { return .apiKey(key) }
        throw ProviderUsageError.signedOut
    }

    /// DSH's version-1 YAML writer uses block mappings and scalar values. Support those forms
    /// (including quoted scalars), reject aliases/multiline secrets instead of guessing.
    private static func credentialFields(_ text: String) throws -> [[String]: String] {
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var fields: [[String]: String] = [:]
            func visit(_ map: [String: Any], path: [String]) {
                for (key, value) in map {
                    if let nested = value as? [String: Any] { visit(nested, path: path + [key]) }
                    else if let string = value as? String { fields[path + [key]] = string }
                    else if let number = value as? NSNumber { fields[path + [key]] = number.stringValue }
                }
            }
            visit(object, path: [])
            return fields
        }
        var fields: [[String]: String] = [:]
        var parents: [(indent: Int, key: String)] = []
        var seen = Set<[String]>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "---" { continue }
            guard !raw.contains("\t"), let colon = line.firstIndex(of: ":") else { throw unsupportedCredentials }
            let indent = raw.prefix(while: { $0 == " " }).count
            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            let key = try scalar(String(line[..<colon]))
            let path = parents.map(\.key) + [key]
            guard seen.insert(path).inserted else { throw unsupportedCredentials }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") { parents.append((indent, key)); continue }
            // Ignore unrelated device/browser grants rather than interpreting their payloads.
            if path == ["version"] || path == ["refs", "DEEPSEEK_API_KEY"] || path.starts(with: ["records", "deepseek-account-platform/default"]) {
                fields[path] = try scalar(value)
            }
        }
        return fields
    }

    private static func scalar(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") {
            guard let data = text.data(using: .utf8), let result = try? JSONDecoder().decode(String.self, from: data) else { throw unsupportedCredentials }
            return result
        }
        if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { throw unsupportedCredentials }
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard !text.isEmpty, !["*", "&", "!", "|", ">", "{", "["].contains(String(text.prefix(1))) else { throw unsupportedCredentials }
        return text.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
    }

    private static func validSecret(_ secret: String) -> Bool {
        !secret.isEmpty && secret.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    static func parseResponse(_ data: Data, credential: Credential, now: Date) throws -> ProviderUsage {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalidResponse }
        var metrics: [ProviderUsageMetric] = []
        let summary: String
        switch credential {
        case .platform:
            if root["code"] as? Int == 40003 { throw ProviderUsageError.signedOut }
            guard root["code"] as? Int == 0, let envelope = root["data"] as? [String: Any],
                  envelope["biz_code"] as? Int == 0, let body = envelope["biz_data"] as? [String: Any],
                  let normal = body["normal_wallets"] as? [[String: Any]],
                  let bonus = body["bonus_wallets"] as? [[String: Any]] else { throw invalidResponse }
            metrics = try wallets(normal, label: "充值余额") + wallets(bonus, label: "赠送余额")
            summary = "DeepSeek 账户余额"
        case .apiKey:
            guard let available = root["is_available"] as? Bool,
                  let balances = root["balance_infos"] as? [[String: Any]] else { throw invalidResponse }
            metrics = try balances.map { row in
                guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency),
                      let total = row["total_balance"] as? String else { throw invalidResponse }
                return .init(label: "API 余额", remainingPercent: nil, value: currency + " " + (try amount(total)), resetsAt: nil)
            }
            summary = available ? "DeepSeek API 按量计费" : "DeepSeek API 余额不足"
        }
        guard !metrics.isEmpty else { throw invalidResponse }
        return ProviderUsage(metrics: metrics, summary: summary, observedAt: now, authenticationVerified: true)
    }

    private static func wallets(_ rows: [[String: Any]], label: String) throws -> [ProviderUsageMetric] {
        try rows.map { row in
            guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency),
                  let balance = row["balance"] as? String else { throw invalidResponse }
            return .init(label: label, remainingPercent: nil, value: currency + " " + (try amount(balance)), resetsAt: nil)
        }
    }

    private static func amount(_ value: String) throws -> String {
        guard value.range(of: #"^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { throw invalidResponse }
        let number = NSDecimalNumber(string: value, locale: Locale(identifier: "en_US_POSIX"))
        guard number != .notANumber else { throw invalidResponse }
        return number.stringValue
    }

    private static var invalidResponse: ProviderUsageError { .requestFailed("DeepSeek 未返回可识别的余额，稍后重试") }
    private static var unsupportedCredentials: ProviderUsageError { .unsupported("暂不支持这份 DeepSeek 登录配置，请在客户端确认账号") }
}
