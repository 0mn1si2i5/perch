import Foundation

/// `agy -p /usage` for the Antigravity CLI's default login. Each run starts the CLI and leaves a log file,
/// so Perch runs it only when the owner presses refresh on the card; the Gemini app is the regular source.
public enum AntigravityCLIUsage {
    public static func query(_ account: Account) async throws -> ProviderUsage {
        guard account.app == .antigravity, let config = account.localProvider, config.kind == .terminal else {
            throw ProviderUsageError.unsupported("此客户端没有 Antigravity CLI 额度查询")
        }
        let defaultRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli").standardizedFileURL
        guard URL(fileURLWithPath: account.profilePath).standardizedFileURL == defaultRoot else {
            throw ProviderUsageError.unsupported("Antigravity CLI 额度查询仅支持本机默认登录目录")
        }
        guard config.target.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: config.target) else {
            throw ProviderUsageError.unsupported("找不到 Antigravity CLI，请先安装 agy")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        let result = await Subprocess.run(config.target, ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"],
                                          environment: environment, currentDirectory: FileManager.default.temporaryDirectory.path,
                                          timeout: 35, outputLimit: 512 * 1024, captureErrors: true)
        try Task.checkCancellation()
        switch result {
        case .failure(.launchFailed): throw ProviderUsageError.requestFailed("无法启动 Antigravity 额度查询")
        case .failure(.timedOut): throw ProviderUsageError.requestFailed("Antigravity 额度查询超时，请稍后重试")
        case .failure(.tooLarge): throw ProviderUsageError.requestFailed("Antigravity 额度响应过大")
        case .success(let output):
            guard output.status == 0 else {
                let message = String(decoding: output.stderr + output.stdout, as: UTF8.self).lowercased()
                if message.contains("authentication required") || message.contains("not authenticated") || message.contains("not logged in") {
                    throw ProviderUsageError.signedOut
                }
                throw ProviderUsageError.requestFailed("Antigravity 额度查询失败，请在客户端确认登录")
            }
            return try parse(output.stdout)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard data.count <= 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "SUCCESS",
              let command = object["command"] as? [String: Any], command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else {
            throw ProviderUsageError.requestFailed("Antigravity 未返回可识别的额度数据，请更新客户端后重试")
        }
        let metrics = groups.prefix(20).flatMap { group in
            (group["buckets"] as? [[String: Any]] ?? []).prefix(20).compactMap { bucket in
                AntigravityBucket.metric(id: bucket["id"], window: bucket["window"], name: bucket["name"],
                                         remaining: bucket["remaining_fraction"], reset: bucket["reset_time"])
            }
        }
        guard !metrics.isEmpty else { throw ProviderUsageError.unsupported("Antigravity 当前登录没有返回可查询的额度") }
        return .init(metrics: metrics, summary: "Antigravity 实时额度", observedAt: now, authenticationVerified: true)
    }
}
