import Foundation

public struct ProviderUsageMetric: Equatable {
    public let label: String
    public let remainingPercent: Double?
    public let value: String?
    public let resetsAt: Date?

    public init(label: String, remainingPercent: Double? = nil, value: String? = nil, resetsAt: Date? = nil) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.value = value
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Equatable {
    public let metrics: [ProviderUsageMetric]
    public let summary: String
    public let observedAt: Date
    public let authenticationVerified: Bool

    public init(metrics: [ProviderUsageMetric], summary: String, observedAt: Date = Date(), authenticationVerified: Bool) {
        self.metrics = metrics
        self.summary = summary
        self.observedAt = observedAt
        self.authenticationVerified = authenticationVerified
    }
}

public enum ProviderUsageError: LocalizedError {
    case signedOut
    case unsupported(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "登录已失效，请在供应商客户端重新登录"
        case .unsupported(let reason), .requestFailed(let reason): return reason
        }
    }
}

/// Antigravity reports Google model allowances as buckets. The CLI and the Gemini app use the same shape with
/// different key names. Only `gemini-` buckets (the Google pool) are shown; third-party model allowances are not.
enum AntigravityBucket {
    static func metric(id: Any?, window: Any?, name: Any?, remaining: Any?, reset: Any?) -> ProviderUsageMetric? {
        guard let id = id as? String, id.hasPrefix("gemini-"),
              let number = remaining as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return nil }
        let window = window as? String ?? ""
        let label = window == "weekly" ? "每周" : window == "5h" ? "5 小时" : String((name as? String ?? window).prefix(80))
        return .init(label: poolLabel(id) + " · " + label, remainingPercent: number.doubleValue * 100,
                     resetsAt: (reset as? String).flatMap(ISO8601.parse))
    }

    /// Argon has its own weekly allowance beside the main Gemini pool; both use `gemini-` bucket ids.
    static func poolLabel(_ bucketID: String) -> String {
        bucketID.localizedCaseInsensitiveContains("argon") ? "Argon" : "Gemini Models"
    }
}
