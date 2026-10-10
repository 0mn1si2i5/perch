import Foundation

public enum PetPose: Int, CaseIterable {
    case idle, salute, thinking, listening, watching, celebrating, confused, lifted
    public var label: String {
        ["待着也挺好", "收到", "正在琢磨", "听歌中", "陪你看片", "搞定了", "挠头", "好家伙，被提起来了"][rawValue]
    }
}

public enum TaskStatus: String {
    case running, completed, failed, interrupted, waiting, unknown
    /// Running or waiting for the user: shown above finished conversations.
    public var isActive: Bool { self == .running || self == .waiting }
    public var label: String {
        switch self {
        case .running: return "进行中"
        case .completed: return "已完成"
        case .failed: return "遇到问题"
        case .interrupted: return "已中断"
        case .waiting: return "等你回应"
        case .unknown: return "无记录"
        }
    }
}

public struct CodexTask: Identifiable, Equatable {
    public let scope = "session"
    public let id: String
    public let title: String
    public let status: TaskStatus
    public let turnID: String
    public let updatedAt: Date
    public let source: String
    /// The session's rollout jsonl, used only for "copy path" and "show in Finder". Never read during polling.
    public let rolloutPath: String?
    public init(id: String, title: String, status: TaskStatus, turnID: String, updatedAt: Date, source: String,
                rolloutPath: String? = nil) {
        self.id = id; self.title = title; self.status = status; self.turnID = turnID
        self.updatedAt = updatedAt; self.source = source; self.rolloutPath = rolloutPath
    }
}

public struct CodexSnapshot: Equatable {
    public let scope = "session"
    public var tasks: [CodexTask]
    public var available: Bool
    public var detail: String
    public init(tasks: [CodexTask] = [], available: Bool = false, detail: String = "正在连接 Codex") {
        self.tasks = tasks; self.available = available; self.detail = detail
    }
}

public enum MediaKind: String { case music, video, unknown, none }
public struct MediaSnapshot: Equatable {
    public let scope = "session"
    public var kind: MediaKind
    public var playing: Bool
    public var source: String
    public init(kind: MediaKind = .none, playing: Bool = false, source: String = "等待播放信息") {
        self.kind = kind; self.playing = playing; self.source = source
    }
}

public enum PetPolicy {
    public static func pose(tasks: [CodexTask], media: MediaSnapshot) -> PetPose {
        if tasks.contains(where: { $0.status == .waiting }) { return .salute }
        // Music/video changes the idle pose. Active work takes priority.
        if tasks.contains(where: { $0.status == .running }) { return .thinking }
        if media.playing && media.kind == .video { return .watching }
        if media.playing && media.kind == .music { return .listening }
        if media.playing && media.kind == .unknown { return .watching }
        return .idle
    }

    public static func threadURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    public static func status(raw: String?, updatedAt: Date, now: Date, appRunning: Bool, waiting: Bool) -> TaskStatus {
        if raw == "completed" { return .completed }
        if raw == "failed" { return .failed }
        if raw == "interrupted" { return .interrupted }
        guard raw == "inProgress" || raw == "running" else { return .unknown }
        // A turn that never finished while its app is gone (or long stale) was cut off. Never call it completed.
        guard appRunning, now.timeIntervalSince(updatedAt) < 30 * 60 else { return .interrupted }
        return waiting ? .waiting : .running
    }
}

public enum MediaPolicy {
    public static func classify(type: String?, bundleID: String, isMusicApp: Bool) -> MediaKind {
        let value = type?.lowercased() ?? ""
        if value.contains("video") { return .video }
        if value.contains("audio") || value.contains("music") { return .music }
        if isMusicApp || ["com.spotify.client", "com.apple.Music", "com.tencent.QQMusicMac"].contains(bundleID) { return .music }
        if ["com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX"].contains(bundleID) { return .video }
        return .unknown
    }
}

public struct CompletionTracker {
    private var running: [String: String] = [:]
    public init() {}
    public mutating func update(_ snapshot: CodexSnapshot) -> CodexTask? {
        guard snapshot.available else { return nil }
        let completion = snapshot.tasks.first {
            $0.status == .completed && running[$0.id] == $0.turnID
        }
        running = Dictionary(uniqueKeysWithValues: snapshot.tasks
            .filter { $0.status == .running || $0.status == .waiting }
            .map { ($0.id, $0.turnID) })
        return completion
    }
}
