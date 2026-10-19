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
