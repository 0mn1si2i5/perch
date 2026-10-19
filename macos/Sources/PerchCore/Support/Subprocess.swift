import Foundation
import Darwin

/// The one way Perch runs helper commands (ps, lsof, open, agy, the media adapter).
/// Each child gets its own process group, so a timeout stops everything it started.
/// The blocking form runs on the caller's DispatchQueue thread; the async form hands it to a
/// DispatchQueue and resumes a continuation, so no Swift concurrency thread waits on a child.
public enum Subprocess {
    public struct Output: Equatable {
        /// Exit code, or -1 when a signal ended the child.
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    public enum Failure: Error, Equatable {
        case launchFailed, timedOut, tooLarge
    }

    private static let queue = DispatchQueue(label: "com.omnis.perch.subprocess", qos: .utility, attributes: .concurrent)
    /// How long the pipes are still read after the child exits. A helper it left running may hold them open.
    static let drainTime: TimeInterval = 2

    /// Blocks for at most `timeout` seconds, plus `drainTime` once the child has exited, plus a short grace
    /// period. Never call it on the main thread.
    /// `outputLimit` applies to each stream; stderr is only read when `captureErrors` is set.
    public static func run(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil,
                           currentDirectory: String? = nil, timeout: TimeInterval, outputLimit: Int = 4 << 20,
                           captureErrors: Bool = false) -> Result<Output, Failure> {
        let child: ChildProcess
        do {
            child = try ChildProcess(executable: executable, arguments: arguments, environment: environment,
                                     currentDirectory: currentDirectory, input: false, captureErrors: captureErrors)
        } catch { return .failure(.launchFailed) }
        let deadline = Date().addingTimeInterval(timeout)
        var stdout = Data(), stderr = Data()
        var failure: Failure?
        var drainUntil: Date?
        var streams = [child.stdout, child.stderr].filter { $0 >= 0 }
        while !streams.isEmpty, failure == nil {
            if drainUntil == nil, child.hasExited() { drainUntil = Date().addingTimeInterval(drainTime) }
            let limit = drainUntil ?? deadline
            guard Date() < limit else {
                if drainUntil == nil { failure = .timedOut }
                break
            }
            // Short reads, so the child's exit is noticed while something else keeps the pipes open.
            switch ChildProcess.read(streams, until: min(limit, Date().addingTimeInterval(0.1))) {
            case .timedOut: continue
            case .end(let fd): streams.removeAll { $0 == fd }
            case .data(let fd, let chunk):
                if fd == child.stdout { stdout.append(chunk) } else { stderr.append(chunk) }
                if stdout.count > outputLimit || stderr.count > outputLimit { failure = .tooLarge }
            }
        }
        if failure == nil, drainUntil == nil, !child.waitForExit(until: deadline) { failure = .timedOut }
        let status = child.finish()
        if let failure { return .failure(failure) }
        return .success(Output(status: status, stdout: stdout, stderr: stderr))
    }

    public static func run(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil,
                           currentDirectory: String? = nil, timeout: TimeInterval, outputLimit: Int = 4 << 20,
                           captureErrors: Bool = false) async -> Result<Output, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: run(executable, arguments, environment: environment,
                                                   currentDirectory: currentDirectory, timeout: timeout,
                                                   outputLimit: outputLimit, captureErrors: captureErrors))
            }
        }
    }
}

/// A child started with posix_spawn in a new process group, with pipes for the streams asked for.
/// `finish()` must be called once; it stops what is left of the group and reaps the child.
final class ChildProcess {
    enum ReadResult: Equatable {
        case data(Int32, Data)
        case end(Int32)
        case timedOut
    }

    let pid: pid_t
    /// Write end of the child's stdin, or -1.
    private(set) var stdin: Int32
    let stdout: Int32
    /// Read end of the child's stderr, or -1 when it goes to /dev/null.
    let stderr: Int32
    private var finished = false

    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(executable: String, arguments: [String], environment: [String: String]?, currentDirectory: String?,
         input: Bool, captureErrors: Bool) throws {
        if input { _ = Self.ignoreBrokenPipe }   // a child that exits early must not take Perch down with SIGPIPE
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1], feed: [Int32] = [-1, -1]
        func closeAll() { (output + errors + feed).filter { $0 >= 0 }.forEach { close($0) } }
        func makePipe(_ fds: inout [Int32]) throws {
            guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
            fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        }
        do {
            try makePipe(&output)
            if captureErrors { try makePipe(&errors) }
            if input { try makePipe(&feed) }
        } catch { closeAll(); throw error }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input { posix_spawn_file_actions_adddup2(&actions, feed[0], 0) }
        else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        if captureErrors { posix_spawn_file_actions_adddup2(&actions, errors[1], 2) }
        else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group; only the three standard streams are inherited; signals start at their defaults.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { $0.map { strdup("\($0.key)=\($0.value)") } + [nil] }
        defer { argv.forEach { free($0) }; envp?.forEach { free($0) } }
        var child: pid_t = 0
        let status = envp.map { posix_spawn(&child, executable, &actions, &attributes, argv, $0) }
            ?? posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        guard status == 0 else { closeAll(); throw POSIXError(POSIXErrorCode(rawValue: status) ?? .ENOENT) }
        [output[1], errors[1], feed[0]].filter { $0 >= 0 }.forEach { close($0) }
        pid = child
        stdin = feed[1]
        stdout = output[0]
        stderr = errors[0]
    }

    deinit { if !finished { _ = finish() } }

    /// Waits for data on any of `fds`; at end of file that descriptor is reported once.
    static func read(_ fds: [Int32], until deadline: Date) -> ReadResult {
        var polls = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            let ready = poll(&polls, nfds_t(polls.count), Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0 { if errno == EINTR { continue }; return .end(fds[0]) }
            guard ready > 0, let item = polls.first(where: { $0.revents != 0 }) else { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(item.fd, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            return count > 0 ? .data(item.fd, Data(buffer.prefix(count))) : .end(item.fd)
        }
    }

    /// Writes all of `data` to the child's stdin; false once the child stopped reading.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard stdin >= 0 else { return false }
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(stdin, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }

    /// Gives a child that waits for input end of file, so it can exit on its own.
    func closeInput() {
        if stdin >= 0 { close(stdin); stdin = -1 }
    }

    /// True once the child has exited. It is not reaped yet, so its process group ID stays reserved.
    func hasExited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    func waitForExit(until deadline: Date) -> Bool {
        while !hasExited() {
            guard Date() < deadline else { return false }
            usleep(5_000)
        }
        return true
    }

    /// Stops the whole group (TERM, then KILL for anything left, grandchildren included), reaps the child
    /// and closes the pipes. Returns the exit code, or -1 when a signal ended the child.
    @discardableResult
    func finish(grace: TimeInterval = 0.5) -> Int32 {
        guard !finished else { return -1 }
        finished = true
        closeInput()
        if !hasExited() {
            killpg(pid, SIGTERM)
            _ = waitForExit(until: Date().addingTimeInterval(grace))
        }
        // Safe while the child is unreaped: its pid, and so the group ID, cannot be reused yet.
        killpg(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        [stdout, stderr].filter { $0 >= 0 }.forEach { close($0) }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
    }
}
