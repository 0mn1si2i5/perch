import AppKit
import Combine
import PerchCore

enum CompanionKind: String, CaseIterable, Identifiable {
    case native, pox
    case deepseekWhale = "deepseek-whale"
    var id: String { rawValue }
    var usesSprites: Bool { self != .native }
    var title: String {
        switch self {
        case .native: return "原生桌宠"
        case .pox: return "Pox"
        case .deepseekWhale: return "DeepSeek 鲸鱼娘"
        }
    }

    // Keep these lines in sync with shared/strings/zh-CN.json's pet.whale keys.
    func poseLabel(_ pose: PetPose) -> String {
        guard self == .deepseekWhale else { return pose.label }
        return ["摸会儿鱼，等口白饭～", "鱼片，等你发话呢 ♡", "呆毛转转，认真想想…", "尾巴跟着节拍晃 ♪",
                "挨着鱼片看一会儿～", "干完啦！白饭加一碗 ✧", "咦？呆毛打结了…？", "呜哇～尾巴悬空啦！"][pose.rawValue]
    }
    var movedText: String { self == .deepseekWhale ? "搬好窝啦，饭碗也带上～" : "好家伙，搬家了。" }
    var completionText: String { self == .deepseekWhale ? "做完啦！开饭～ ♡" : "搞定一个。" }
    var doubleClickText: String? { self == .deepseekWhale ? "收到，鱼片！这就来～" : nil }
}

/// Desktop-pet state. Codex tasks are pushed in by PerchModel; this type owns pose, bubble and media only.
final class PetModel: ObservableObject {
    @Published var tasks: [CodexTask] = []
    @Published var media = MediaSnapshot()
    @Published var pose: PetPose = .idle
    @Published var bubble: String? = nil
    @Published var mediaEnabled: Bool
    @Published var quiet: Bool
    @Published var petSize: Double
    @Published var previewing = false
    /// Capability, selected character and on-screen visibility are independent persisted choices.
    @Published private(set) var enabled: Bool
    @Published private(set) var visible: Bool
    @Published private(set) var character: CompanionKind
    var configurationChanged: (() -> Void)?
    var usesCharacterTheme: Bool { enabled && character == .pox }
    private var animates: Bool { enabled && visible && character.usesSprites }
    private let defaults: UserDefaults
    var changed: (() -> Void)?
    var resize: (() -> Void)?
    private let monitor = MediaMonitor()
    private var timer: Timer?
    private var overrideUntil = Date.distantPast
    private var previewUntil = Date.distantPast

    var statusLabel: String {
        let active = tasks.filter { $0.status == .running }.count
        if character == .deepseekWhale {
            if !previewing && pose == .thinking { return "\(active) 个任务，努力游！" }
            if !previewing && pose == .watching && media.kind == .unknown { return "有声音耶，陪你听～" }
            return character.poseLabel(pose)
        }
        return previewing ? "动作预览" : pose == .thinking ? "Codex · \(active) 个任务" : pose.label
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialEnabled = defaults.bool(forKey: "petEnabled")
        enabled = initialEnabled
        character = CompanionKind(rawValue: defaults.string(forKey: "petCharacter") ?? "") ?? .native
        visible = initialEnabled && (defaults.object(forKey: "companionVisible") as? Bool ?? true)
        defaults.set("personal", forKey: "scope")
        mediaEnabled = defaults.object(forKey: "mediaEnabled") as? Bool ?? true
        quiet = defaults.bool(forKey: "quiet")
        petSize = defaults.object(forKey: "petSize") as? Double ?? 190
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        visible = enabled
        persistConfiguration()
    }

    func setVisible(_ visible: Bool) {
        guard enabled, self.visible != visible else { return }
        self.visible = visible
        persistConfiguration()
    }

    func select(_ character: CompanionKind) {
        guard self.character != character else { return }
        self.character = character
        // Temporary feedback belongs to the character that produced it.
        let currentMedia = media
        clearActivity()
        media = currentMedia
        persistConfiguration()
    }

    private func persistConfiguration() {
        defaults.set(enabled, forKey: "petEnabled")
        defaults.set(visible, forKey: "companionVisible")
        defaults.set(character.rawValue, forKey: "petCharacter")
        if animates { start(); refreshPose() } else {
            timer?.invalidate()
            timer = nil
            clearActivity()
        }
        configurationChanged?()
    }

    private func clearActivity() {
        media = MediaSnapshot()
        bubble = nil
        previewing = false
        overrideUntil = .distantPast
        previewUntil = .distantPast
        pose = .idle
    }

    func start() {
        guard animates, timer == nil else { return }
        pollMedia()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pollMedia() }
    }

    /// All Codex tasks across accounts; `completed` is a turn observed running earlier in this app session.
    func update(tasks: [CodexTask], completed: CodexTask?) {
        self.tasks = tasks
        guard animates else { return }
        if let completed, !quiet {
            react(.celebrating, text: "\(character.completionText)\n\(String(completed.title.prefix(28)))", seconds: 7)
        } else {
            refreshPose()
        }
    }

    func pollMedia() {
        guard animates else { return }
        if mediaEnabled {
            monitor.poll { [weak self] media in
                guard let self, self.animates, self.mediaEnabled else { return }
                self.media = media
                self.refreshPose()
            }
        } else {
            media = MediaSnapshot(source: "媒体感知已关闭")
            refreshPose()
        }
    }

    func refreshPose() {
        guard animates else { return }
        if previewing && Date() >= previewUntil { previewing = false }
        if Date() >= overrideUntil {
            pose = PetPolicy.pose(tasks: tasks, media: media)
            bubble = nil
        }
        changed?()
    }

    func react(_ pose: PetPose, text: String? = nil, seconds: TimeInterval = 3, preview: Bool = false) {
        guard animates else { return }
        overrideUntil = Date().addingTimeInterval(seconds)
        self.pose = pose
        bubble = quiet ? nil : text
        if preview { previewing = true; previewUntil = overrideUntil }
        changed?()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.refreshPose() }
    }

    func preview(_ pose: PetPose) {
        react(pose, text: "动作预览 · \(character.poseLabel(pose))", seconds: 8, preview: true)
    }

    func saveSettings() {
        if quiet { bubble = nil }
        defaults.set(mediaEnabled, forKey: "mediaEnabled")
        defaults.set(quiet, forKey: "quiet")
        defaults.set(petSize, forKey: "petSize")
        resize?()
        pollMedia()
    }
}
