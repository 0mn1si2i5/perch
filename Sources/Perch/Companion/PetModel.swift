import AppKit
import Combine
import PerchCore

enum CompanionKind: String, CaseIterable, Identifiable {
    case native, pox
    var id: String { rawValue }
    var title: String { self == .native ? "原生桌宠" : "Pox" }
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
    private var animates: Bool { enabled && visible && character == .pox }
    private let defaults: UserDefaults
    var changed: (() -> Void)?
    var resize: (() -> Void)?
    private let monitor = MediaMonitor()
    private var timer: Timer?
    private var overrideUntil = Date.distantPast
    private var previewUntil = Date.distantPast

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
        // A preview/override from Pox must never carry into a different character.
        clearActivity()
        persistConfiguration()
    }

    private func persistConfiguration() {
        defaults.set(enabled, forKey: "petEnabled")
        defaults.set(visible, forKey: "companionVisible")
        defaults.set(character.rawValue, forKey: "petCharacter")
        if animates { start() } else {
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
            react(.celebrating, text: "搞定一个。\n\(String(completed.title.prefix(28)))", seconds: 7)
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
        if previewing && Date() >= previewUntil { previewing = false }
        if Date() >= overrideUntil {
            pose = PetPolicy.pose(tasks: tasks, media: media)
            bubble = pose == .watching && media.kind == .unknown && !quiet ? "媒体播放中" : nil
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
        react(pose, text: "动作预览 · \(pose.label)", seconds: 8, preview: true)
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
