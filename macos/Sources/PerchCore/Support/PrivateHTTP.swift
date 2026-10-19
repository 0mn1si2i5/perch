import Foundation

/// The one URLSession setup for Perch's quota and balance reads: ephemeral, no cookies, cache or stored
/// credentials, and redirects refused, so a token is never forwarded to another address.
enum PrivateHTTP {
    /// Pass a configuration only to inject URLProtocol fixtures in tests; it is copied, not changed.
    static func session(timeout: TimeInterval, resourceTimeout: TimeInterval,
                        configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
