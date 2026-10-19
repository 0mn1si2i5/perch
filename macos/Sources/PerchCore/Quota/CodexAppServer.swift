import Foundation

/// Asks one account's Codex for its plan and rate limits over the app-server JSON-RPC protocol on stdio.
public enum CodexAppServer {
    public struct Answer {
        /// `account/read` result reduced to `requiresOpenaiAuth` and `account.{type, planType}`; nil if it failed.
        public var account: [String: Any]?
        /// `account/rateLimits/read` result; nil if it failed (API-key accounts always fail here).
        public var rateLimits: [String: Any]?
    }

    public enum Failure: Error, Equatable {
        case notFound, startFailed, timedOut, exited, initializeFailed, unreadable

        public var reason: String {
            switch self {
            case .notFound: return "找不到 Codex 命令行工具"
            case .startFailed: return "Codex 命令行工具无法启动"
            case .timedOut: return "查询超时（10 秒）"
            case .exited: return "Codex 提前退出"
            case .initializeFailed: return "这个版本的 Codex 不支持额度查询"
            case .unreadable: return "Codex 没有返回可识别的额度"
            }
        }
    }

    /// Protocol state: initialize → (initialized, account/read, account/rateLimits/read) → both answers.
    struct Exchange {
        static let initialize: [String: Any] = ["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "perch", "title": "Perch", "version": "1"],
            "capabilities": ["optOutNotificationMethods": [String]()]]]

        private var answer = Answer()
        private var accountDone = false, limitsDone = false

        /// Returns the messages to send next, and the outcome once it is known.
        mutating func receive(_ message: [String: Any]) -> (send: [[String: Any]], done: Result<Answer, Failure>?) {
            guard let id = (message["id"] as? NSNumber)?.intValue else { return ([], nil) }   // a notification
            switch id {
            case 1:
                if message["error"] != nil { return ([], .failure(.initializeFailed)) }
                return ([["method": "initialized"],
                         ["id": 2, "method": "account/read", "params": ["refreshToken": false]],
                         ["id": 3, "method": "account/rateLimits/read", "params": NSNull()]], nil)
            case 2:
                accountDone = true
                answer.account = (message["result"] as? [String: Any]).map(Self.withoutIdentity)
            case 3:
                limitsDone = true
                answer.rateLimits = message["result"] as? [String: Any]
            default:
                return ([], nil)
            }
            return ([], accountDone && limitsDone ? .success(answer) : nil)
        }

        /// Keeps only what classification needs; the email and other identity fields are dropped at once.
        private static func withoutIdentity(_ result: [String: Any]) -> [String: Any] {
            var kept: [String: Any] = ["requiresOpenaiAuth": result["requiresOpenaiAuth"] as? Bool ?? false]
            if let account = result["account"] as? [String: Any] {
                kept["account"] = account.filter { $0.key == "type" || $0.key == "planType" }
            }
            return kept
        }
    }

    /// Starts `codex app-server`, runs the exchange and ends the process group. Blocks for at most `timeout`
    /// seconds plus a short grace period; call it on a DispatchQueue, never on the main thread.
    public static func query(cli: String, codexHome: String, timeout: TimeInterval = 10) -> Result<Answer, Failure> {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        let child: ChildProcess
        do {
            // stderr may contain local paths; it goes to /dev/null and is never read.
            child = try ChildProcess(executable: cli, arguments: ["app-server", "--listen", "stdio://"], environment: environment,
                                     currentDirectory: nil, input: true, captureErrors: false)
        } catch { return .failure(.startFailed) }
        // Closing stdin first lets a well-behaved server exit; anything left in its group is then stopped.
        defer { child.finish() }
        func send(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            child.write(data + Data([10]))
        }
        send(Exchange.initialize)
        let deadline = Date().addingTimeInterval(timeout)
        var exchange = Exchange(), buffer = Data()
        while true {
            switch ChildProcess.read([child.stdout], until: deadline) {
            case .timedOut: return .failure(.timedOut)
            case .end: return .failure(.exited)   // end of file: the process quit
            case .data(_, let chunk):
                buffer.append(chunk)
                if buffer.count > 4 << 20 { return .failure(.unreadable) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[buffer.startIndex..<end])
                    buffer.removeSubrange(buffer.startIndex...end)
                    // Lines that are not JSON-RPC (logs) are skipped.
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    let step = exchange.receive(message)
                    step.send.forEach(send)
                    if let done = step.done { return done }
                }
            }
        }
    }
}
