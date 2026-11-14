import Foundation
import CryptoKit

/// An in-memory cache scoped to the configured home, reference and current key. The key itself is not retained.
public final class DshApiBalance: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var identity = ""
    private var generation: UInt64 = 0
    private var nextQuery = Date.distantPast
    private var cached: DshBalanceResult?

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    public func clear() {
        lock.withLock {
            generation &+= 1; identity = ""; nextQuery = .distantPast; cached = nil
        }
    }

    private func unavailable(_ message: String) -> DshBalanceResult {
        clear()
        return .init(error: message)
    }

    public static func officialEndpoint(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.deepseek.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    public func read(route: DshBilling, home: String, manual: Bool = false) async -> DshBalanceResult {
        guard route.provider == "deepseek-official" else { clear(); return .init() }
        guard route.configured else { return unavailable("API Key 未配置，请在 dsh 模型设置中配置。") }
        guard route.source == "file" else { return unavailable("当前凭据来源暂不支持余额查询（仅支持标准文件来源）。") }
        guard Self.officialEndpoint(route.baseURL) else { return unavailable("模型端点不是 DeepSeek 官方 HTTPS 地址，未发送 API Key。") }
        guard !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable("请选择已有实例的余额凭据目录（DSH_HOME）。")
        }
        let key: String, fingerprint: String
        do {
            key = try Self.readKey(home: home, reference: route.reference)
            fingerprint = Self.fingerprint(home: home, reference: route.reference, key: key)
        } catch { return unavailable(Self.credentialError(error)) }

        let state: (UInt64, DshBalanceResult?) = lock.withLock {
            if identity != fingerprint {
                generation &+= 1; identity = fingerprint; cached = nil; nextQuery = .distantPast
            }
            if !manual, let cached, Date() < nextQuery { return (generation, cached) }
            nextQuery = Date().addingTimeInterval(300)
            return (generation, nil)
        }
        if let cached = state.1 { return cached }

        let result: Result<ProviderUsage, Error>
        do { result = .success(try await DeepSeekUsage.query(credential: .apiKey(key), configuration: configuration, includeAPIBreakdown: true)) }
        catch { result = .failure(error) }

        // A key removed or changed during the request cannot inherit the previous key's wallet, even on failure.
        do {
            guard Self.fingerprint(home: home, reference: route.reference,
                                   key: try Self.readKey(home: home, reference: route.reference)) == fingerprint else {
                return unavailable("API Key 已变更，请刷新余额。")
            }
        } catch { return unavailable("无法确认当前 API Key，已清除余额缓存。") }

        return lock.withLock {
            guard generation == state.0, identity == fingerprint else {
                return .init(error: "连接或凭据已变更，请刷新余额。")
            }
            switch result {
            case .success(let usage): cached = .init(usage: usage)
            case .failure(let error):
                let message: String
                switch error {
                case ProviderUsageError.signedOut: message = "DeepSeek API 鉴权失败，请检查 dsh 中的 API Key。"
                case let ProviderUsageError.requestFailed(detail), let ProviderUsageError.unsupported(detail): message = detail
                default: message = Task.isCancelled ? "DeepSeek API 余额查询已取消。" : "DeepSeek API 余额查询失败，请稍后重试。"
                }
                cached = .init(usage: cached?.usage, error: message)
            }
            return cached!
        }
    }

    private static func readKey(home: String, reference: String) throws -> String {
        guard home.hasPrefix("/") else { throw DshError.invalid("余额凭据目录必须是绝对路径。") }
        let file = URL(fileURLWithPath: home).appendingPathComponent(".credentials.yaml")
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 262_144 else {
                throw DshError.invalid("dsh 标准凭据文件过大或格式不兼容。")
            }
            return try DeepSeekUsage.apiKey(credentialData: Data(contentsOf: file), reference: reference)
        } catch let error as DshError { throw error }
        catch let error as ProviderUsageError { throw error }
        catch { throw DshError.invalid("无法读取 dsh 标准凭据文件，请检查目录与权限。") }
    }

    private static func credentialError(_ error: Error) -> String {
        switch error {
        case let DshError.invalid(message): return message
        case ProviderUsageError.signedOut: return "dsh 标准凭据文件中未找到当前模型引用的 API Key。"
        default: return "dsh 标准凭据文件格式不兼容，未读取其他来源的 Key。"
        }
    }

    private static func fingerprint(home: String, reference: String, key: String) -> String {
        let path = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data((path + "\0" + reference + "\0" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
