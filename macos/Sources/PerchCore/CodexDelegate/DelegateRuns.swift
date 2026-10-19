import Foundation

/// One `codex exec` run started by the codex-delegate skill. The skill writes each run into its own
/// directory under the runs root: meta.json, events.jsonl (codex --json), last.md and, once finished, result.json.
public struct DelegateRun: Identifiable, Equatable {
    public enum Kind: String { case worker, review }
    public enum State: Equatable {
        case running
        case succeeded
        case failed(Int32)
        /// No result.json and the launcher process is gone: killed or crashed.
        case interrupted
    }

    public let id: String
    public let directory: URL
    public let kind: Kind
    public let title: String
    public let workdir: String
    public let model: String
    public let startedAt: Date
    public var endedAt: Date?
    public var state: State
    public var events: [DelegateEvent]
    public var changedFiles: [String]
    public var commandCount: Int
    public var tokens: Int?
    /// Final report (last.md), read once the run is over.
    public var report: String?

    public var isRunning: Bool { state == .running }
    /// The newest event worth showing on one line.
    public var latest: DelegateEvent? { events.last(where: { $0.kind != .reasoning }) ?? events.last }
}

public struct DelegateEvent: Identifiable, Equatable {
    public enum Kind: String { case message, reasoning, command, fileChange, tool, search, todo, error, turn }
    public enum Status: Equatable { case running, ok, failed }

    public let id: String
    public let kind: Kind
    public var text: String
    public var detail: String?
    public var status: Status
}

/// Reads the runs root incrementally: events.jsonl is read from the last offset, so polling every second
/// stays cheap while a run is active. Not thread-safe: use one reader from one serial queue.
public final class DelegateRunReader {
    public static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_DELEGATE_RUNS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-delegate/runs", isDirectory: true)
    }

    public let root: URL
    /// Finished runs older than this are not listed.
    public var keepFinished: TimeInterval = 24 * 3600
    public var maxRuns = 12
    static let maxEvents = 300

    private struct Cache {
        var run: DelegateRun
        var offset: UInt64 = 0
        var remainder = Data()
        var pid: Int32
        var finished = false
    }
    private var cache: [String: Cache] = [:]
    private let isAlive: (Int32) -> Bool

    public init(root: URL = DelegateRunReader.defaultRoot, isAlive: @escaping (Int32) -> Bool = DelegateRunReader.processAlive) {
        self.root = root
        self.isAlive = isAlive
    }

    public static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func read(now: Date = Date()) -> [DelegateRun] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        // Directory names start with a sortable timestamp; newest first.
        var runs: [DelegateRun] = []
        var seen = Set<String>()
        for name in names.sorted(by: >) where !name.hasPrefix(".") {
            guard runs.count < maxRuns else { break }
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard var entry = cache[name] ?? load(dir) else { continue }
            seen.insert(name)
            if !entry.finished { update(&entry, dir: dir) }
            cache[name] = entry
            let run = entry.run
            if !run.isRunning, now.timeIntervalSince(run.endedAt ?? run.startedAt) > keepFinished { continue }
            runs.append(run)
        }
        cache = cache.filter { seen.contains($0.key) }
        return runs
    }

    private func load(_ dir: URL) -> Cache? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = meta["id"] as? String ?? dir.lastPathComponent
        let started = (meta["startedAt"] as? String).flatMap(Self.parseDate)
            ?? (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let run = DelegateRun(
            id: id, directory: dir,
            kind: DelegateRun.Kind(rawValue: meta["kind"] as? String ?? "") ?? .worker,
            title: (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
            workdir: meta["workdir"] as? String ?? "",
            model: meta["model"] as? String ?? "",
            startedAt: started, endedAt: nil, state: .running,
            events: [], changedFiles: [], commandCount: 0, tokens: nil, report: nil)
        return Cache(run: run, pid: (meta["pid"] as? NSNumber)?.int32Value ?? 0)
    }

    private func update(_ entry: inout Cache, dir: URL) {
        readEvents(&entry, url: dir.appendingPathComponent("events.jsonl"))
        if let data = try? Data(contentsOf: dir.appendingPathComponent("result.json")),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            readEvents(&entry, url: dir.appendingPathComponent("events.jsonl"))   // pick up the last lines
            let code = (result["exitCode"] as? NSNumber)?.int32Value ?? -1
            entry.run.state = code == 0 ? .succeeded : .failed(code)
            entry.run.endedAt = (result["endedAt"] as? String).flatMap(Self.parseDate) ?? Date()
            entry.finished = true
        } else if !isAlive(entry.pid) {
            entry.run.state = .interrupted
            entry.run.endedAt = (try? dir.appendingPathComponent("events.jsonl")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? entry.run.startedAt
            entry.finished = true
        }
        if entry.finished {
            // Anything still marked running never completed.
            for index in entry.run.events.indices where entry.run.events[index].status == .running {
                entry.run.events[index].status = entry.run.state == .succeeded ? .ok : .failed
            }
            entry.run.report = (try? String(contentsOf: dir.appendingPathComponent("last.md"), encoding: .utf8))
                .map { String($0.prefix(20_000)) }
        }
    }

    private func readEvents(_ entry: inout Cache, url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        if end < entry.offset { entry.offset = 0; entry.remainder = Data(); entry.run.events = [] }   // file was replaced
        guard end > entry.offset else { return }
        try? handle.seek(toOffset: entry.offset)
        guard let chunk = try? handle.read(upToCount: Int(end - entry.offset)) else { return }
        entry.offset = end
        var buffer = entry.remainder + chunk
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        entry.remainder = buffer
        for line in lines { apply(line, to: &entry.run) }
        if entry.run.events.count > Self.maxEvents { entry.run.events.removeFirst(entry.run.events.count - Self.maxEvents) }
    }

    func apply(_ line: Data, to run: inout DelegateRun) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any],
                  var event = Self.event(item, completed: type == "item.completed") else { return }
            if let index = run.events.lastIndex(where: { $0.id == event.id }) {
                if event.detail == nil { event.detail = run.events[index].detail }
                run.events[index] = event
            } else {
                run.events.append(event)
                if event.kind == .command { run.commandCount += 1 }
            }
            if event.kind == .fileChange, let changes = item["changes"] as? [[String: Any]] {
                for path in changes.compactMap({ $0["path"] as? String }) where !run.changedFiles.contains(path) {
                    run.changedFiles.append(path)
                }
            }
        case "turn.completed":
            if let usage = object["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                run.tokens = (run.tokens ?? 0) + input + output
            }
        case "turn.failed", "error":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? object["message"] as? String ?? "运行出错"
            run.events.append(DelegateEvent(id: "error-\(run.events.count)", kind: .error, text: message, detail: nil, status: .failed))
        default:
            break
        }
    }

    static func event(_ item: [String: Any], completed: Bool) -> DelegateEvent? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let rawStatus = item["status"] as? String
        var status: DelegateEvent.Status = completed ? .ok : .running
        if rawStatus == "failed" || rawStatus == "declined" { status = .failed }
        switch type {
        case "agent_message":
            return DelegateEvent(id: id, kind: .message, text: item["text"] as? String ?? "", detail: nil, status: .ok)
        case "reasoning":
            return DelegateEvent(id: id, kind: .reasoning, text: item["text"] as? String ?? "", detail: nil, status: .ok)
        case "command_execution":
            let command = shortCommand(item["command"] as? String ?? "")
            let exitCode = (item["exit_code"] as? NSNumber)?.intValue
            if let exitCode, exitCode != 0 { status = .failed }
            let output = (item["aggregated_output"] as? String).flatMap { $0.isEmpty ? nil : String($0.suffix(4000)) }
            return DelegateEvent(id: id, kind: .command, text: command, detail: output, status: status)
        case "file_change":
            let changes = (item["changes"] as? [[String: Any]]) ?? []
            let text = changes.map { change in
                let path = change["path"] as? String ?? "?"
                let kind = change["kind"] as? String ?? "update"
                let mark = kind == "add" ? "+" : kind == "delete" ? "−" : "~"
                return "\(mark) \((path as NSString).lastPathComponent)"
            }.joined(separator: "  ")
            let paths = changes.compactMap { $0["path"] as? String }.joined(separator: "\n")
            return DelegateEvent(id: id, kind: .fileChange, text: text.isEmpty ? "修改文件" : text,
                                 detail: paths.isEmpty ? nil : paths, status: status)
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            return DelegateEvent(id: id, kind: .tool, text: name.isEmpty ? "工具调用" : name, detail: nil, status: status)
        case "web_search":
            return DelegateEvent(id: id, kind: .search, text: item["query"] as? String ?? "搜索", detail: nil, status: status)
        case "todo_list":
            let todos = (item["items"] as? [[String: Any]]) ?? []
            let done = todos.filter { $0["completed"] as? Bool == true }.count
            let lines = todos.map { ($0["completed"] as? Bool == true ? "✓ " : "· ") + ($0["text"] as? String ?? "") }
            return DelegateEvent(id: id, kind: .todo, text: "计划 \(done)/\(todos.count)",
                                 detail: lines.joined(separator: "\n"), status: .ok)
        case "error":
            let message = item["message"] as? String ?? "错误"
            // codex prints a warning item for under-development features on every run; it is not a failure.
            if message.hasPrefix("Under-development features enabled") { return nil }
            return DelegateEvent(id: id, kind: .error, text: message, detail: nil, status: .failed)
        default:
            return nil
        }
    }

    /// `/bin/zsh -lc "cmd"` → `cmd`.
    static func shortCommand(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if rest.count >= 2, let first = rest.first, (first == "\"" || first == "'"), rest.last == first {
                rest = String(rest.dropFirst().dropLast())
                if first == "\"" { rest = rest.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            }
            return rest
        }
        return command
    }

    static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}
