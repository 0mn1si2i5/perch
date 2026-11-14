import Foundation
import Darwin

/// This mode runs before AppKit. Only the host owns the child, so quitting the panel leaves dsh running.
public enum DshHost {
    public static func run(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == "--dsh-host" else { return nil }
        guard arguments.count == 4 else { return 2 }
        // Detach from the GUI/terminal session and keep every new runtime file private.
        _ = setsid()
        _ = umask(0o077)
        do {
            let state = try DshState(root: URL(fileURLWithPath: arguments[2]), key: arguments[3])
            try state.prepare()
            let lease = try DshLease(url: state.lockURL)
            guard lease.acquired else { return 0 }
            let finished = DispatchSemaphore(value: 0)
            let result = HostResult()
            Task {
                result.value = await serve(state)
                finished.signal()
            }
            finished.wait()
            return withExtendedLifetime(lease) { result.value }
        } catch { return 1 }
    }

    /// Never retain arbitrary output: only a bounded startup announcement may become an authorization.
    static func announcedURL(_ line: String) -> String? {
        guard line.hasPrefix("dsh web: http://"), line.utf8.count <= 8192 else { return nil }
        let value = String(line.dropFirst(9).split(separator: " ", maxSplits: 1).first ?? "")
        return (try? DshConnection.validateURL(value))?.absoluteString
    }

    private static func serve(_ state: DshState) async -> Int32 {
        let credentials = DshAuthorizationStore()
        var runtime = DshRuntime(phase: "starting", hostPID: getpid(), detail: "dsh 正在启动…")
        var child: ChildProcess?
        var drain: Task<Void, Never>?
        do {
            // The previous host may have died while its node process survived. Never duplicate that home.
            if DshState.childAlive(try state.read()) { return 0 }
            let data = try Data(contentsOf: state.launchURL)
            guard data.count <= 65_536 else { throw DshError.invalid("dsh 启动配置不可读。") }
            let launch = try JSONDecoder().decode(DshLaunch.self, from: data)
            try state.write(runtime)
            let process = try ChildProcess(executable: launch.node, arguments: launch.arguments,
                                           environment: launch.environment, currentDirectory: launch.workingDirectory,
                                           input: false, captureErrors: false)
            child = process
            runtime.childPID = process.pid
            guard let identity = DshState.processIdentity(process.pid) else {
                throw DshError.invalid("dsh 已退出，请检查 Node 版本和安装。")
            }
            runtime.childIdentity = identity
            try state.write(runtime)
            let announcement = Announcement()
            drain = Task.detached(priority: .utility) {
                var pending = Data()
                var overflow = false
                while !Task.isCancelled && !process.hasExited() {
                    switch ChildProcess.read([process.stdout], until: Date().addingTimeInterval(0.1)) {
                    case .timedOut: continue
                    case .end: return
                    case .data(_, let data):
                        for byte in data {
                            if byte == 10 {
                                if !overflow, let line = String(data: pending, encoding: .utf8), let url = announcedURL(line) {
                                    await announcement.set(url)
                                }
                                pending.removeAll(keepingCapacity: true); overflow = false
                            } else if pending.count < 8192 && !overflow { pending.append(byte) }
                            else { pending.removeAll(keepingCapacity: true); overflow = true }
                        }
                    }
                }
            }
            let deadline = Date().addingTimeInterval(60)
            var url: String?
            while Date() < deadline && !process.hasExited() && !state.stopRequested(runtime) {
                url = await announcement.value
                if url != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let url else { throw DshError.invalid("dsh 未能启动 Web 服务，请检查安装与 Web profile。") }
            let connection = try DshConnection(authorization: .init(url: url))
            try await connection.authenticate()
            _ = try await connection.sessions()
            guard !process.hasExited(), !state.stopRequested(runtime) else {
                throw DshError.invalid("dsh 启动已停止。")
            }
            try credentials.write(connection.authorization, key: state.credentialKey, interactive: false)
            runtime.phase = "ready"; runtime.detail = ""
            runtime.origin = DshState.origin(try DshConnection.validateURL(connection.authorization.url))
            try state.write(runtime)
            while !process.hasExited() && !state.stopRequested(runtime) {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            drain?.cancel()
            await drain?.value
            _ = process.finish()
            child = nil
            runtime.phase = "stopped"; runtime.detail = "dsh 服务已停止。"
            try state.write(runtime)
            return 0
        } catch {
            drain?.cancel()
            await drain?.value
            _ = child?.finish()
            runtime.phase = "error"
            runtime.detail = (error as? DshError)?.localizedDescription ?? "dsh 启动失败，请检查安装、Node 版本和钥匙串权限。"
            try? state.write(runtime)
            return 1
        }
    }

    private actor Announcement {
        var value: String?
        func set(_ url: String) { if value == nil { value = url } }
    }
    private final class HostResult { var value: Int32 = 1 }
}
