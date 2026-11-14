import Foundation

public enum DshMode: String, Codable, CaseIterable {
    case source, npm, external
    public var displayName: String {
        switch self {
        case .source: return "源码构建版"
        case .npm: return "npm 安装版"
        case .external: return "连接已有实例"
        }
    }
}

/// Public launch configuration only. Authorization URLs and cookies belong in Keychain.
public struct DshConfiguration: Codable, Equatable {
    public var mode: DshMode
    public var installationPath: String
    public var nodePath: String
    public var profile: String
    public var balanceHome: String
    public init(mode: DshMode = .npm, installationPath: String = "", nodePath: String = "",
                profile: String = "web", balanceHome: String = "") {
        self.mode = mode; self.installationPath = installationPath; self.nodePath = nodePath
        self.profile = profile; self.balanceHome = balanceHome
    }
}

public struct DshAuthorization: Codable, Equatable {
    public var url: String
    public var cookie: String
    public init(url: String, cookie: String = "") { self.url = url; self.cookie = cookie }
}

public struct DshSession: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    public let updatedAt: Date
    public let status: TaskStatus
    public let statusLabel: String
    public init(id: String, title: String, workingDirectory: String = "", updatedAt: Date,
                status: TaskStatus, statusLabel: String? = nil) {
        self.id = id; self.title = title; self.workingDirectory = workingDirectory; self.updatedAt = updatedAt
        self.status = status; self.statusLabel = statusLabel ?? status.label
    }
    public func changingStatus(_ status: TaskStatus, label: String? = nil) -> DshSession {
        .init(id: id, title: title, workingDirectory: workingDirectory, updatedAt: updatedAt,
              status: status, statusLabel: label)
    }
}

public struct DshSnapshot: Equatable {
    public var sessions: [DshSession]
    public var running: Bool
    public var cached: Bool
    public var detail: String
    public var observedAt: Date?
    public init(sessions: [DshSession] = [], running: Bool = false, cached: Bool = false,
                detail: String = "dsh 尚未连接", observedAt: Date? = nil) {
        self.sessions = sessions; self.running = running; self.cached = cached
        self.detail = detail; self.observedAt = observedAt
    }
}

public struct DshBalances: Equatable {
    public var official: ProviderUsage?
    public var officialError: String?
    public var api: ProviderUsage?
    public var apiError: String?
    public init(official: ProviderUsage? = nil, officialError: String? = nil,
                api: ProviderUsage? = nil, apiError: String? = nil) {
        self.official = official; self.officialError = officialError
        self.api = api; self.apiError = apiError
    }
}

public struct DshBilling: Equatable {
    public let detail: String
    public let provider: String
    public let reference: String
    public let configured: Bool
    public let source: String
    public let baseURL: String
    public init(detail: String, provider: String = "", reference: String = "", configured: Bool = false,
                source: String = "", baseURL: String = "") {
        self.detail = detail; self.provider = provider; self.reference = reference
        self.configured = configured; self.source = source; self.baseURL = baseURL
    }
}

public struct DshBalanceResult: Equatable {
    public var usage: ProviderUsage?
    public var error: String?
    public init(usage: ProviderUsage? = nil, error: String? = nil) { self.usage = usage; self.error = error }
}

/// Only messages written by Perch cross this boundary; raw RPC bodies and credentials are never errors.
public enum DshError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}
