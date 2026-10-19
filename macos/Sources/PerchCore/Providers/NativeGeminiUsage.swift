import Foundation
import Darwin

/// Reads the running Gemini application's embedded Antigravity service. Never starts the app.
public enum NativeGeminiUsage {
    private static let bundleID = "com.google.GeminiMacOS"
    private static let openApp = "请先打开 Gemini 应用中的 Antigravity，再刷新额度"

    public static func query(_ account: Account) async throws -> ProviderUsage {
        let endpoint = try await endpoint(account)
        let client = Client()
        let csrf = try await client.csrf(endpoint)
        let quota = try await client.rpc("RetrieveUserQuotaSummary", body: ["forceRefresh": true], endpoint: endpoint, csrf: csrf)
        return try parseQuota(quota)
    }

    private static func endpoint(_ account: Account) async throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/" + bundleID)
        guard URL(fileURLWithPath: account.profilePath).standardizedFileURL == root.standardizedFileURL,
              let config = account.localProvider, config.kind == .application,
              let bundle = Bundle(url: URL(fileURLWithPath: config.target)), bundle.bundleIdentifier == bundleID,
              let executable = bundle.executableURL else {
            throw ProviderUsageError.unsupported("仅支持本机 Gemini 应用的默认登录目录")
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/agy").path
        let port = try await Task.detached(priority: .utility) {
            let snapshot = try command("/bin/ps", ["-axo", "pid=,ppid=,uid=,command="])
            let candidates = helperCandidates(snapshot: String(decoding: snapshot, as: UTF8.self),
                                              helper: helper, appExecutable: executable.path, uid: getuid())
            for candidate in candidates {
                guard processPath(candidate.pid) == helper, processPath(candidate.parent) == executable.path else { continue }
                let sockets = try command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(candidate.pid),
                    "-iTCP:" + String(candidate.port), "-sTCP:LISTEN", "-Fn"])
                let lines = String(decoding: sockets, as: UTF8.self).split(separator: "\n")
                if lines.contains(Substring("n127.0.0.1:" + String(candidate.port))) { return candidate.port }
            }
            throw ProviderUsageError.unsupported(openApp)
        }.value
        try Task.checkCancellation()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    struct Helper: Equatable { let pid: Int32; let parent: Int32; let port: Int }

    static func helperCandidates(snapshot: String, helper: String, appExecutable: String, uid: uid_t) -> [Helper] {
        struct Row { let pid: Int32; let parent: Int32; let uid: uid_t; let command: String }
        let rows: [Row] = snapshot.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4, let pid = Int32(parts[0]), let parent = Int32(parts[1]), let owner = uid_t(parts[2]) else { return nil }
            return Row(pid: pid, parent: parent, uid: owner, command: String(parts[3]))
        }
        return rows.compactMap { row in
            guard row.uid == uid, row.command.hasPrefix(helper + " "),
                  rows.contains(where: { $0.pid == row.parent && $0.uid == uid && ($0.command == appExecutable || $0.command.hasPrefix(appExecutable + " ")) }) else { return nil }
            let args = row.command.dropFirst(helper.count + 1).split(separator: " ").map(String.init)
            guard args.contains("--hub"), args.contains("--use_host_auth"), args.contains("--app_data_dir=antigravity"),
                  args.contains("--read_host_bridge_token_from_stdin"),
                  let raw = args.first(where: { $0.hasPrefix("--hub-port=") }),
                  let port = Int(raw.dropFirst("--hub-port=".count)), (1...65535).contains(port),
                  let bridge = args.first(where: { $0.hasPrefix("--host_bridge_url=") }),
                  let url = URLComponents(string: String(bridge.dropFirst("--host_bridge_url=".count))),
                  url.scheme == "http", url.host == "127.0.0.1", url.port != nil, url.user == nil, url.password == nil else { return nil }
            return Helper(pid: row.pid, parent: row.parent, port: port)
        }
    }

    static func csrfToken(_ data: Data) throws -> String {
        guard data.count <= 65_536, let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "\"?csrfToken\"?\\s*:\\s*\"([^\"\\r\\n]+)\""),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw ProviderUsageError.requestFailed("Gemini 本地服务未提供可用的连接凭据，请重新打开 Antigravity")
        }
        let token = String(html[range])
        guard token.utf8.count <= 4096 else { throw invalidResponse }
        return token
    }

    static func parseQuota(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try json(data)
        guard let response = object["response"] as? [String: Any], let groups = response["groups"] as? [[String: Any]] else { throw invalidResponse }
        // Gemini's native host deliberately hides third-party models in its Models & Usage UI.
        let metrics = groups.prefix(20).flatMap { group -> [ProviderUsageMetric] in
            guard let buckets = group["buckets"] as? [[String: Any]] else { return [] }
            return buckets.prefix(20).compactMap { bucket in
                guard let id = bucket["bucketId"] as? String, id.hasPrefix("gemini-"),
                      let value = bucket["remainingFraction"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else { return nil }
                let window = bucket["window"] as? String ?? ""
                let label = window == "weekly" ? "每周" : window == "5h" ? "5 小时" : String((bucket["displayName"] as? String ?? window).prefix(80))
                return .init(label: GoogleProviderUsage.poolLabel(id) + " · " + label, remainingPercent: value.doubleValue * 100,
                             resetsAt: (bucket["resetTime"] as? String).flatMap(ISO8601.parse))
            }
        }
        guard !metrics.isEmpty else { throw ProviderUsageError.unsupported("Gemini 当前登录没有返回可查询的 Antigravity 额度") }
        return .init(metrics: metrics, summary: "Gemini 内 Antigravity", observedAt: now, authenticationVerified: true)
    }

    private static let invalidResponse = ProviderUsageError.requestFailed("Gemini 本地额度服务返回的数据无法识别")
    private static func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalidResponse }
        return object
    }

    private final class Client {
        let session: URLSession
        init() {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
            config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            session = URLSession(configuration: config, delegate: NoProviderRedirects(), delegateQueue: nil)
        }
        deinit { session.invalidateAndCancel() }
        func csrf(_ endpoint: URL) async throws -> String { try csrfToken(await send(URLRequest(url: endpoint), limit: 65_536)) }
        func rpc(_ name: String, body: [String: Any], endpoint: URL, csrf: String) async throws -> Data {
            var request = URLRequest(url: endpoint.appendingPathComponent("exa.language_server_pb.LanguageServerService/" + name))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await send(request, limit: 1_048_576)
        }
        private func send(_ request: URLRequest, limit: Int) async throws -> Data {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw invalidResponse }
                if http.statusCode == 401 { throw ProviderUsageError.signedOut }
                guard (200..<300).contains(http.statusCode) else { throw ProviderUsageError.requestFailed("Gemini 本地额度请求失败（HTTP \(http.statusCode)）") }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < limit else { throw invalidResponse }
                    data.append(byte)
                }
                return data
            } catch let error as ProviderUsageError { throw error }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw ProviderUsageError.requestFailed("无法连接 Gemini 本地服务，请打开应用中的 Antigravity 后重试")
            }
        }
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let output = NativeProcessOutput()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                output.append(data)
            }
        }
        let timeout = finished.wait(timeout: .now() + 4) == .timedOut
        if timeout {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = drained.wait(timeout: .now() + 1)
        guard !timeout, let data = output.data else { throw ProviderUsageError.requestFailed("无法检查 Gemini 本地服务，请稍后重试") }
        return data
    }
}

private final class NativeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var overflow = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count + data.count <= 2_097_152 { buffer.append(data) } else { overflow = true }
    }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return overflow ? nil : buffer }
}
