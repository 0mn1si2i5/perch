import Foundation

/// Estimates what a Claude Code CLI account (a `CLAUDE_CONFIG_DIR`) spent in the current period from its own
/// session transcripts. Console API organizations expose no balance to the CLI login, so this reads only local
/// files and makes no request. Every logged API response carries its token usage; the price table turns that into
/// dollars. Checked against Claude Code's own `total_cost_usd` for the same session.
public enum ClaudeCodeCredit {
    /// USD per million tokens.
    struct Price: Equatable {
        let input: Double, output: Double, write5m: Double, write1h: Double, read: Double
        /// Claude Haiku 5.5 bills prompts over 100K tokens at 5x.
        var longPromptMultiplier: Double = 1
    }

    /// Anthropic first-party API rates, as of 2026-10.
    static let prices: [(String, Price)] = [
        ("claude-fable-5-1", .init(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 0.25)),
        ("claude-mythos-5-1", .init(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 0.25)),
        ("claude-fable-5", .init(input: 10, output: 50, write5m: 12.5, write1h: 20, read: 1)),
        ("claude-opus-5-5", .init(input: 4, output: 20, write5m: 5, write1h: 8, read: 0.2)),
        ("claude-opus-5", .init(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("claude-opus-4-8", .init(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("claude-opus-4-7", .init(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("claude-opus-4-6", .init(input: 5, output: 25, write5m: 6.25, write1h: 10, read: 0.5)),
        ("claude-sonnet-5-5", .init(input: 2, output: 10, write5m: 2.5, write1h: 4, read: 0.2)),
        ("claude-sonnet-5", .init(input: 2, output: 10, write5m: 2.5, write1h: 4, read: 0.2)),
        ("claude-sonnet-4-6", .init(input: 3, output: 15, write5m: 3.75, write1h: 6, read: 0.3)),
        ("claude-haiku-5-5", .init(input: 0.1, output: 0.5, write5m: 0.125, write1h: 0.2, read: 0.01, longPromptMultiplier: 5)),
        ("claude-haiku-4-5", .init(input: 1, output: 5, write5m: 1.25, write1h: 2, read: 0.1)),
    ]
    static let webSearchPerRequest = 0.01

    /// Longest matching id first, so `claude-opus-5-5` is not priced as `claude-opus-5`.
    static func price(for model: String) -> Price? {
        let id = model.lowercased()
        return prices.sorted { $0.0.count > $1.0.count }.first { key, _ in
            id == key || id.hasPrefix(key + "-") || id.hasPrefix(key + "[") || id.hasPrefix(key + "@")
        }?.1
    }

    public struct Estimate: Equatable {
        public var spent: Double = 0
        public var messages = 0
        /// Models with token usage but no price; their usage is left out of `spent`.
        public var unpriced: Set<String> = []
        /// Each priced response: when it was logged and what it cost, oldest first.
        public var charges: [Charge] = []
    }

    public struct Charge: Equatable {
        public let at: Date
        public let cost: Double
    }

    /// What is left of each grant at `now`, and spending no grant covered.
    public struct Allocation: Equatable {
        public var remaining: [Double]
        public var uncovered: Double
    }

    /// Charges are paid in time order from the grants in effect at that moment, the one that expires first first.
    /// Anthropic does not document the order; this is the assumption the panel states.
    public static func allocate(_ charges: [Charge], to grants: [CreditGrant]) -> Allocation {
        var left = grants.map(\.amount), uncovered = 0.0
        let order = grants.indices.sorted { grants[$0].end < grants[$1].end }
        for charge in charges.sorted(by: { $0.at < $1.at }) {
            var due = charge.cost
            for i in order where grants[i].start <= charge.at && charge.at < grants[i].end && left[i] > 0 && due > 0 {
                let paid = min(left[i], due)
                left[i] -= paid; due -= paid
            }
            uncovered += due
        }
        return Allocation(remaining: left, uncovered: uncovered)
    }

    static func cost(_ usage: [String: Any], model: String) -> Double? {
        guard let price = price(for: model) else { return nil }
        func n(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        let input = n(usage["input_tokens"]), output = n(usage["output_tokens"])
        let read = n(usage["cache_read_input_tokens"]), written = n(usage["cache_creation_input_tokens"])
        let split = usage["cache_creation"] as? [String: Any]
        let write1h = n(split?["ephemeral_1h_input_tokens"])
        // Without the TTL split every write is a 5-minute write.
        let write5m = split == nil ? written : n(split?["ephemeral_5m_input_tokens"])
        let multiplier = (input + read + written > 100_000 ? price.longPromptMultiplier : 1)
            * ((usage["speed"] as? String) == "fast" ? 2 : 1)
        let tokens = input * price.input + output * price.output + read * price.read
            + write5m * price.write5m + write1h * price.write1h
        let searches = n((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
        return tokens * multiplier / 1_000_000 + searches * webSearchPerRequest
    }

    /// Sums assistant responses logged since `since` under `<configDir>/projects`, subagent transcripts included.
    /// Claude Code writes one line per content block with the same usage, so responses are counted once by id.
    public static func estimate(configDir: URL, since: Date) -> Estimate {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return Estimate() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>(), result = Estimate()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.contentModificationDate ?? .distantFuture) >= since,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any], let model = message["model"] as? String,
                      let stamp = (object["timestamp"] as? String).flatMap(iso.date(from:)), stamp >= since else { continue }
                let key = message["id"] as? String ?? object["requestId"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
                guard seen.insert(key).inserted else { continue }
                if let dollars = cost(usage, model: model) {
                    result.spent += dollars
                    result.messages += 1
                    result.charges.append(Charge(at: stamp, cost: dollars))
                } else if (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0 > 0 {
                    result.unpriced.insert(model)
                }
            }
        }
        result.charges.sort { $0.at < $1.at }
        return result
    }

    static func dollars(_ value: Double) -> String {
        String(format: value < 1 ? "$%.4f" : "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func cents(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func query(_ account: Account, now: Date = Date()) async throws -> ProviderUsage {
        guard account.app == .claudeCode else { throw ProviderUsageError.unsupported("不是 Claude Code CLI 账号") }
        let grants = (account.creditGrants ?? []).sorted { $0.end < $1.end }
        // Usage before the first grant cannot draw on any of them; without grants, show this month's spend.
        let since = grants.map(\.start).min() ?? Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let found = await Task.detached(priority: .utility) {
            estimate(configDir: URL(fileURLWithPath: account.profilePath), since: since)
        }.value
        let charges = found.charges.filter { $0.at <= now }
        var metrics: [ProviderUsageMetric] = []
        var summary = "按本目录的会话记录和 API 价格估算，以 Console 为准。"
        if grants.isEmpty {
            metrics.append(.init(label: "本月已用", value: dollars(charges.reduce(0) { $0 + $1.cost })))
            metrics.append(.init(label: "额度", value: "未设置，右键卡片设置"))
        } else {
            let result = allocate(charges, to: grants)
            let active = grants.indices.filter { grants[$0].start <= now && now < grants[$0].end }
            // Rounded down, so a small spend never shows as the full amount.
            let left = active.map { (result.remaining[$0] * 100).rounded(.down) / 100 }.reduce(0, +)
            let total = active.map { grants[$0].amount }.reduce(0, +)
            metrics.append(.init(label: "已用", value: dollars(charges.reduce(0) { $0 + $1.cost })))
            metrics.append(.init(label: "估算剩余", value: cents(left) + " / " + cents(total),
                                 resetsAt: active.map { grants[$0].end }.min()))
            for i in active {
                metrics.append(.init(label: grants[i].expiresOn + " 到期",
                                     value: cents((result.remaining[i] * 100).rounded(.down) / 100) + " / " + cents(grants[i].amount),
                                     resetsAt: grants[i].end))
            }
            summary += "按到期日从早到晚扣费（Anthropic 没有公开扣费顺序，这是假设），日期按 UTC，到期日当天仍可用。"
            if result.uncovered > 0.005 { summary += "有 " + cents(result.uncovered) + " 的用量不在任何额度的有效期内。" }
        }
        if !found.unpriced.isEmpty {
            summary += "没有价格的模型未计入：" + found.unpriced.sorted().joined(separator: "、") + "。"
        }
        return ProviderUsage(metrics: metrics, summary: summary, observedAt: now, authenticationVerified: false)
    }
}
