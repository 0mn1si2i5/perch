import Foundation

public enum APIProtocol: String, Codable, CaseIterable {
    case openAI, anthropic, gemini

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }
}

/// Connection metadata only. Credentials are held separately in the macOS Keychain.
public struct APIProviderConfiguration: Codable, Equatable {
    public var presetID: String
    public var displayName: String
    /// API root including its version, e.g. https://api.openai.com/v1.
    public var baseURL: String
    public var protocolKind: APIProtocol
    public var model: String
    public var dashboardURL: String

    public init(presetID: String = "custom", displayName: String = "自定义供应商", baseURL: String,
                protocolKind: APIProtocol = .openAI, model: String = "", dashboardURL: String = "") {
        self.presetID = presetID
        self.displayName = displayName
        self.baseURL = baseURL
        self.protocolKind = protocolKind
        self.model = model
        self.dashboardURL = dashboardURL
    }

    public func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIProviderError.emptyName
        }
        _ = try Self.validatedURL(baseURL)
        if !dashboardURL.isEmpty { _ = try Self.validatedURL(dashboardURL) }
    }

    public var modelsURL: URL {
        get throws {
            try validate()
            return try Self.validatedURL(baseURL).appendingPathComponent("models")
        }
    }

    static func validatedURL(_ value: String) throws -> URL {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              let url = components.url else { throw APIProviderError.invalidURL }
        return url
    }
}

public struct ProviderPreset: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let configuration: APIProviderConfiguration

    public init(id: String, name: String, baseURL: String, protocolKind: APIProtocol = .openAI,
                dashboardURL: String = "") {
        self.id = id
        self.name = name
        self.configuration = APIProviderConfiguration(presetID: id, displayName: name, baseURL: baseURL,
                                                       protocolKind: protocolKind, dashboardURL: dashboardURL)
    }

    // Model names are deliberately discovered from the provider, rather than frozen in presets.
    public static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", dashboardURL: "https://platform.openai.com"),
        .init(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", protocolKind: .anthropic,
              dashboardURL: "https://platform.claude.com"),
        .init(id: "gemini", name: "Gemini API", baseURL: "https://generativelanguage.googleapis.com/v1beta", protocolKind: .gemini,
              dashboardURL: "https://aistudio.google.com"),
        .init(id: "deepseek", name: "DeepSeek API", baseURL: "https://api.deepseek.com", dashboardURL: "https://platform.deepseek.com"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", dashboardURL: "https://openrouter.ai/settings/keys"),
        .init(id: "ollama", name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", dashboardURL: "https://ollama.com"),
        .init(id: "custom", name: "自定义供应商", baseURL: "")
    ]
}

public enum APIProviderError: LocalizedError, Equatable {
    case emptyName, invalidURL, invalidKey, invalidResponse, redirectRefused, networkFailure, timedOut, tooManyPages
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "供应商名称不能为空"
        case .invalidURL: return "请输入完整 HTTPS 地址（本机服务可用 HTTP），地址不能包含凭据、查询参数或片段"
        case .invalidKey: return "API Key 不能包含换行或控制字符"
        case .invalidResponse: return "服务未返回可识别的模型列表"
        case .redirectRefused: return "服务要求跳转，已停止请求；请填写最终 API 地址"
        case .networkFailure: return "无法连接供应商，请检查地址与网络"
        case .timedOut: return "供应商连接超时"
        case .tooManyPages: return "模型列表分页过多，请在供应商控制台查看"
        case .httpStatus(let status): return "模型列表请求失败（HTTP \(status)）"
        }
    }
}
