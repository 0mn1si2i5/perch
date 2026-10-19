import Foundation
import PerchCore

/// Adapts provider data to the same quota windows used by Codex and Claude.
enum ProviderUsagePresentation {
    struct Row: Equatable {
        let label: String
        let value: String
        let unit: String?
    }

    static func windows(_ usage: ProviderUsage) -> [QuotaWindow] {
        usage.metrics.compactMap { metric in
            guard let remaining = metric.remainingPercent, remaining.isFinite, (0...100).contains(remaining),
                  let minutes = minutes(metric.label) else { return nil }
            return QuotaWindow(minutes: minutes, usedPercent: 100 - remaining, resetsAt: metric.resetsAt, pool: pool(metric.label))
        }.sorted { ($0.minutes, $0.pool == nil ? 0 : 1) < ($1.minutes, $1.pool == nil ? 0 : 1) }
    }

    static func display(usage: ProviderUsage?, error: String?) -> QuotaDisplay {
        let values = usage.map { Self.windows($0) } ?? []
        return QuotaDisplay(value: values.isEmpty ? nil : .windows(values), observedAt: usage?.observedAt,
                            cached: usage != nil && error != nil, liveFailure: error)
    }

    static func rows(_ usage: ProviderUsage) -> [Row] {
        if let balances = balances(usage.metrics) { return balances }
        return usage.metrics.compactMap { metric in
            if let remaining = metric.remainingPercent {
                guard minutes(metric.label) == nil else { return nil }
                let value = remaining.isFinite && (0...100).contains(remaining)
                    ? String(Int((100 - remaining).rounded())) + "%" : "暂无数据"
                return Row(label: metric.label, value: value, unit: nil)
            }
            return Row(label: metric.label, value: metric.value ?? "暂无数据", unit: nil)
        }
    }

    static func details(_ usage: ProviderUsage) -> String {
        let metrics = usage.metrics.map { metric in
            let value = metric.value ?? metric.remainingPercent.map {
                String(format: "剩余 %.1f%%", locale: Locale(identifier: "en_US_POSIX"), $0)
            } ?? "暂无数据"
            return metric.label + "：" + value
                + (metric.resetsAt.map { "；重置于 " + QuotaFormat.resetTimestamp($0) } ?? "")
        }
        return (metrics + [usage.summary, "记录时间：" + QuotaFormat.resetTimestamp(usage.observedAt)]).joined(separator: "\n")
    }

    /// The main Gemini pool keeps the plain 5h／周 labels; any other named pool is shown before the duration.
    private static func pool(_ label: String) -> String? {
        let parts = label.components(separatedBy: " · ")
        guard parts.count > 1, parts[0] != "Gemini Models" else { return nil }
        return parts[0]
    }

    private static func minutes(_ label: String) -> Int? {
        let window = label.components(separatedBy: " · ").last ?? label
        switch window {
        case "5 小时", "5h": return 300
        case "每周", "周", "weekly": return 10080
        case "每日", "daily": return 1440
        default: return nil
        }
    }

    private static func balances(_ metrics: [ProviderUsageMetric]) -> [Row]? {
        var currencies: [String] = [], components: [String: Decimal] = [:], totals: [String: Decimal] = [:]
        guard !metrics.isEmpty else { return nil }
        for metric in metrics {
            let isTotal = ["API 余额", "总余额", "余额"].contains(metric.label)
            guard metric.remainingPercent == nil, isTotal || ["充值余额", "赠送余额"].contains(metric.label),
                  let value = metric.value else { return nil }
            let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["CNY", "USD"].contains(parts[0]),
                  parts[1].range(of: #"^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
                  let amount = Decimal(string: parts[1], locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
            let currency = parts[0]
            if !currencies.contains(currency) { currencies.append(currency) }
            if isTotal { totals[currency] = amount }
            else { components[currency, default: 0] += amount }
        }
        // API total_balance already includes paid and granted balances. Never add its details twice.
        let values = currencies.map { (currency: $0, amount: totals[$0] ?? components[$0] ?? 0) }
        guard values.allSatisfy({ !$0.amount.isNaN }) else { return nil }
        let nonzero = values.filter { $0.amount != 0 }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return (nonzero.isEmpty ? values : nonzero).map {
            let formatted = formatter.string(from: NSDecimalNumber(decimal: $0.amount)) ?? NSDecimalNumber(decimal: $0.amount).stringValue
            return Row(label: "余额", value: formatted, unit: $0.currency)
        }
    }
}
