import Foundation
import CryptoKit
import Darwin

/// Public process metadata only. The URL and cookie never appear in this file.
struct DshRuntime: Codable, Equatable {
    var phase: String
    var instance: String = UUID().uuidString
    var hostPID: Int32 = 0
    var childPID: Int32 = 0
    var childIdentity: String = ""
    var origin: String = ""
    var detail: String = ""
}

struct DshState {
    let root: URL
    let key: String
    let lockRoot: URL
    var directory: URL { root.appendingPathComponent("dsh").appendingPathComponent(key) }
    var launchURL: URL { directory.appendingPathComponent("launch.json") }
    var runtimeURL: URL { directory.appendingPathComponent("runtime.json") }
    var stopURL: URL { directory.appendingPathComponent("stop") }
    var lockURL: URL { lockRoot.appendingPathComponent(key + ".lock") }
    var credentialKey: String { Self.hash(root.standardizedFileURL.resolvingSymlinksInPath().path + ":" + key) }

    init(root: URL, key: String, lockRoot: URL? = nil) throws {
        guard key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw DshError.invalid("无效的 dsh 实例标识。")
        }
        self.root = root.standardizedFileURL
        self.key = key
        // The lock is per user/home even when two Perch data roots are used.
        self.lockRoot = lockRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/DshLocks")
    }

    static func key(for account: Account) -> String {
        account.dshWeb?.mode == .external ? hash("account:" + account.id)
            : hash("home:" + URL(fileURLWithPath: account.profilePath).standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func prepare() throws {
        try Self.privateDirectory(root.appendingPathComponent("dsh"))
        try Self.privateDirectory(directory)
        try Self.privateDirectory(lockRoot)
    }

    static func privateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func write(_ runtime: DshRuntime) throws { try prepare(); try Self.write(runtime, to: runtimeURL) }

    func read() throws -> DshRuntime? {
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else { return nil }
        guard let size = try runtimeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: runtimeURL), let state = try? JSONDecoder().decode(DshRuntime.self, from: data) else {
            throw DshError.invalid("dsh 运行记录不可读，请重新连接。")
        }
        return state
    }

    func hostAlive() -> Bool {
        guard FileManager.default.fileExists(atPath: lockURL.path) else { return false }
        guard let lease = try? DshLease(url: lockURL) else { return true } // An unreadable lease is never permission to start another host.
        return !lease.acquired
    }

    func requestStop(_ runtime: DshRuntime) throws {
        try Self.write(runtime.instance, to: stopURL)
    }

    func stopRequested(_ runtime: DshRuntime) -> Bool {
        guard let data = try? Data(contentsOf: stopURL), data.count < 512,
              let instance = try? JSONDecoder().decode(String.self, from: data) else { return false }
        return instance == runtime.instance
    }

    static func processIdentity(_ pid: Int32) -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["TZ"] = "UTC"
        guard pid > 0, kill(pid, 0) == 0,
              case .success(let output) = Subprocess.run("/bin/ps", ["-p", String(pid), "-o", "lstart=,comm="],
                                                        environment: environment, timeout: 2, outputLimit: 16_384), output.status == 0 else { return nil }
        let identity = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : identity
    }

    static func childAlive(_ runtime: DshRuntime?) -> Bool {
        guard let runtime, !runtime.childIdentity.isEmpty else { return false }
        return processIdentity(runtime.childPID) == runtime.childIdentity
    }

    static func origin(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil; components.fragment = nil; components.path = "/"
        return components.url!.absoluteString
    }
}

/// The descriptor is close-on-exec: a child must not accidentally keep a dead host's lease alive.
final class DshLease {
    let acquired: Bool
    private let descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DshError.invalid("无法锁定 dsh 实例，请检查数据目录权限。") }
        acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        if !acquired, errno != EWOULDBLOCK && errno != EAGAIN {
            close(descriptor)
            throw DshError.invalid("无法读取 dsh 实例锁。")
        }
    }
    deinit { if acquired { _ = flock(descriptor, LOCK_UN) }; close(descriptor) }
}
