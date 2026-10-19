import Foundation

/// Read-only model discovery. Success is not proof of inference access, billing, or key validity:
/// some providers expose their catalog publicly.
public final class APIProviderClient {
    private let session: URLSession

    /// Injectable session configuration permits URLProtocol fixtures without live requests.
    /// The client always owns the redirect delegate, including with injected configurations.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: NoProviderRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func check(configuration: APIProviderConfiguration, key: String?) async throws -> [String] {
        var request = try Self.makeRequest(configuration: configuration, key: key)
        let initialURL = request.url!
        var names: [String] = []
        var seenPages = Set<String>()
        for _ in 0..<20 {
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if (error as? URLError)?.code == .timedOut { throw APIProviderError.timedOut }
                throw APIProviderError.networkFailure
            }
            guard let http = response as? HTTPURLResponse else { throw APIProviderError.invalidResponse }
            guard !(300..<400).contains(http.statusCode) else { throw APIProviderError.redirectRefused }
            guard (200..<300).contains(http.statusCode) else { throw APIProviderError.httpStatus(http.statusCode) }
            let page = try Self.parse(data, protocolKind: configuration.protocolKind)
            names.append(contentsOf: page.names)
            guard let next = page.next else { return Array(Set(names)).sorted() }
            guard seenPages.insert(next).inserted else { throw APIProviderError.invalidResponse }
            var url = URLComponents(url: initialURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: configuration.protocolKind == .gemini ? "pageToken" : "after_id", value: next)]
            request.url = url.url
        }
        throw APIProviderError.tooManyPages
    }

    static func makeRequest(configuration: APIProviderConfiguration, key: String?) throws -> URLRequest {
        var request = URLRequest(url: try configuration.modelsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard key.rangeOfCharacter(from: .controlCharacters) == nil else { throw APIProviderError.invalidKey }
        switch configuration.protocolKind {
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        case .gemini:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        }
        return request
    }

    private static func parse(_ data: Data, protocolKind: APIProtocol) throws -> (names: [String], next: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json[protocolKind == .gemini ? "models" : "data"] as? [[String: Any]] else {
            throw APIProviderError.invalidResponse
        }
        let field = protocolKind == .gemini ? "name" : "id"
        let names = try rows.map { row -> String in
            guard var name = row[field] as? String, !name.isEmpty else { throw APIProviderError.invalidResponse }
            if protocolKind == .gemini, name.hasPrefix("models/") { name = String(name.dropFirst(7)) }
            guard !name.isEmpty else { throw APIProviderError.invalidResponse }
            return name
        }
        if protocolKind == .gemini, let next = json["nextPageToken"] as? String, !next.isEmpty { return (names, next) }
        if protocolKind == .anthropic, json["has_more"] as? Bool == true {
            guard let next = json["last_id"] as? String, !next.isEmpty else { throw APIProviderError.invalidResponse }
            return (names, next)
        }
        return (names, nil)
    }
}

final class NoProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
