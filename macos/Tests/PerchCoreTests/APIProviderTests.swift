import Foundation
import XCTest
@testable import PerchCore

final class APIProviderTests: XCTestCase {
    func testPresetsHaveVersionedModelEndpointsAndRoundTripWithoutCredentials() throws {
        let expected = [
            "openai": "https://api.openai.com/v1/models",
            "anthropic": "https://api.anthropic.com/v1/models",
            "gemini": "https://generativelanguage.googleapis.com/v1beta/models",
            "deepseek": "https://api.deepseek.com/models",
            "openrouter": "https://openrouter.ai/api/v1/models",
            "ollama": "http://127.0.0.1:11434/v1/models"
        ]
        for preset in ProviderPreset.all where preset.id != "custom" {
            XCTAssertEqual(try preset.configuration.modelsURL.absoluteString, expected[preset.id])
            let data = try JSONEncoder().encode(preset.configuration)
            XCTAssertEqual(try JSONDecoder().decode(APIProviderConfiguration.self, from: data), preset.configuration)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["presetID", "displayName", "baseURL", "protocolKind", "model", "dashboardURL"]))
        }
    }

    func testRejectsUnsafeOrAmbiguousEndpoints() throws {
        for address in ["", "example.com", "file:///tmp/a", "http://example.com/v1", "https://user:secret@example.com/v1",
                        "https://example.com/v1?key=secret", "https://example.com/v1?", "https://example.com/#secret",
                        "https://example.com:0", "https://example.com:65536", "https://example.com/a b",
                        "http://localhost.example.com", "http://127.0.0.1.example.com", "https://example.com\n"] {
            XCTAssertThrowsError(try APIProviderConfiguration(baseURL: address).validate(), address) { error in
                XCTAssertEqual(error as? APIProviderError, .invalidURL)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        for address in ["https://api.example.com/custom/v2/", "http://localhost:8080/v1", "http://127.0.0.1/v1", "http://[::1]:11434/v1"] {
            XCTAssertNoThrow(try APIProviderConfiguration(baseURL: address).validate(), address)
        }
        XCTAssertThrowsError(try APIProviderConfiguration(displayName: "  ", baseURL: "https://example.com").validate())
        XCTAssertThrowsError(try APIProviderConfiguration(baseURL: "https://example.com", dashboardURL: "javascript:alert(1)").validate())
    }

    func testRequestsKeepKeysInProtocolHeadersAndNeverInURLs() throws {
        for protocolKind in APIProtocol.allCases {
            let config = APIProviderConfiguration(baseURL: "https://example.com/v1", protocolKind: protocolKind)
            let request = try APIProviderClient.makeRequest(configuration: config, key: "fixture-key")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), protocolKind == .openAI ? "Bearer fixture-key" : nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), protocolKind == .anthropic ? "fixture-key" : nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), protocolKind == .anthropic ? "2023-06-01" : nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), protocolKind == .gemini ? "fixture-key" : nil)
        }
        let local = APIProviderConfiguration(baseURL: "http://localhost:11434/v1")
        XCTAssertNil(try APIProviderClient.makeRequest(configuration: local, key: nil).value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try APIProviderClient.makeRequest(configuration: local, key: "fixture\r\ninjection"))
    }

    func testOpenAICompatibleResponseDeduplicatesAndSorts() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return (200, #"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"z-model"}]}"#)
        }
        let models = try await client.check(configuration: .init(baseURL: "https://fixture.invalid/v1"), key: "fixture-key")
        XCTAssertEqual(models, ["a-model", "z-model"])
    }

    func testGeminiPaginationUsesHeaderKeyAndEscapesCursor() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            if components.queryItems == nil {
                return (200, #"{"models":[{"name":"models/gemini-a"}],"nextPageToken":"cursor&key=untrusted"}"#)
            }
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "pageToken", value: "cursor&key=untrusted")])
            XCTAssertEqual(components.host, "fixture.invalid")
            return (200, #"{"models":[{"name":"models/gemini-b"}]}"#)
        }
        let models = try await client.check(configuration: .init(baseURL: "https://fixture.invalid/v1beta", protocolKind: .gemini), key: "fixture-key")
        XCTAssertEqual(models, ["gemini-a", "gemini-b"])
    }

    func testAnthropicPaginationAndNoCredentialRequirementForPublicCatalog() async throws {
        let client = makeClient { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            if request.url?.query == nil {
                return (200, #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"claude-a"}"#)
            }
            XCTAssertEqual(request.url?.query, "after_id=claude-a")
            return (200, #"{"data":[{"id":"claude-b"}],"has_more":false}"#)
        }
        let models = try await client.check(configuration: .init(baseURL: "https://fixture.invalid/v1", protocolKind: .anthropic), key: nil)
        XCTAssertEqual(models, ["claude-a", "claude-b"])
    }

    func testResponseErrorsDoNotExposeBodyOrRedirectLocation() async throws {
        for (status, body, expected) in [
            (401, "secret response body", APIProviderError.httpStatus(401)),
            (302, "https://other.invalid/?key=secret", APIProviderError.redirectRefused),
            (200, #"{"error":"secret"}"#, APIProviderError.invalidResponse),
            (200, #"{"data":[{"id":42}]}"#, APIProviderError.invalidResponse)
        ] {
            let client = makeClient { _ in (status, body) }
            do {
                _ = try await client.check(configuration: .init(baseURL: "https://fixture.invalid/v1"), key: "secret")
                XCTFail("Expected error")
            } catch {
                XCTAssertEqual(error as? APIProviderError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("other.invalid"))
            }
        }
    }

    func testNetworkErrorsAreSanitized() async throws {
        let client = makeClient { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "secret", NSURLErrorFailingURLStringErrorKey: "https://secret.invalid"])
        }
        do {
            _ = try await client.check(configuration: .init(baseURL: "https://fixture.invalid/v1"), key: nil)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? APIProviderError, .timedOut)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testRedirectDelegateNeverForwardsRequestWithCredentials() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://fixture.invalid/v1/models")!
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        var forwarded = URLRequest(url: URL(string: "https://other.invalid")!)
        forwarded.setValue("fixture-key", forHTTPHeaderField: "x-goog-api-key")
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://other.invalid"])!
        var called = false
        NoProviderRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: forwarded) {
            called = true
            XCTAssertNil($0)
        }
        XCTAssertTrue(called)
    }

    func testRepeatedPaginationTokenFailsInsteadOfLooping() async throws {
        let client = makeClient { _ in (200, #"{"models":[{"name":"models/a"}],"nextPageToken":"repeat"}"#) }
        do {
            _ = try await client.check(configuration: .init(baseURL: "https://fixture.invalid", protocolKind: .gemini), key: nil)
            XCTFail("Expected invalid pagination")
        } catch { XCTAssertEqual(error as? APIProviderError, .invalidResponse) }
    }

    private func makeClient(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> APIProviderClient {
        APIProviderFixtureProtocol.lock.lock()
        APIProviderFixtureProtocol.handler = handler
        APIProviderFixtureProtocol.lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIProviderFixtureProtocol.self]
        return APIProviderClient(configuration: configuration)
    }
}

private final class APIProviderFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, body) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
