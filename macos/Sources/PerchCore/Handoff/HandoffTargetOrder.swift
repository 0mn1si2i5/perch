import Foundation

/// The handoff menu lists the accounts with the most quota left first.
public enum HandoffTargetOrder {
    /// Most quota left first; targets without quota data keep their order at the end.
    public static func ordered<Target>(_ targets: [Target], remaining: (Target) -> Double?) -> [Target] {
        let scored = targets.enumerated().map { (offset: $0.offset, target: $0.element, left: remaining($0.element)) }
        return scored.sorted { a, b in
            switch (a.left, b.left) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.target)
    }

    /// "剩 62%", "不限", or nil when there is no quota data to show.
    public static func label(remaining: Double?) -> String? {
        guard let remaining else { return nil }
        return remaining.isInfinite ? "不限" : "剩 \(Int(remaining.rounded()))%"
    }
}

extension QuotaDisplay {
    /// Percent left in the tightest window; `.infinity` for a plan without limits; nil when no window was read.
    /// A window that has already reset counts as full.
    public func remainingPercent(now: Date) -> Double? {
        switch value {
        case .windows(let windows)? where !windows.isEmpty:
            return windows.map { $0.hasReset(now: now) ? 100 : min(100, max(0, 100 - $0.usedPercent)) }.min()
        case .unlimited?:
            return .infinity
        default:
            return nil
        }
    }
}

extension ProviderUsage {
    /// The smallest percentage left among the metrics that report one; nil when none do (e.g. a money balance).
    public func remainingPercent(now: Date) -> Double? {
        metrics.compactMap { metric in
            metric.remainingPercent.map { left in metric.resetsAt.map { $0 <= now } == true ? 100 : min(100, max(0, left)) }
        }.min()
    }
}
