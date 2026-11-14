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

    // Only this character opts into the whale namespace; other characters keep pet.*.
    func dialogueKey(_ key: String) -> String {
        "pet.\(self == .deepseekWhale ? "whale." : "")\(key)"
    }
    func poseLabel(_ pose: PetPose) -> String {
        Strings.get(dialogueKey("pose.\(pose.rawValue)"))
    }
    var movedText: String { Strings.get(dialogueKey("moved")) }
    var completionText: String { Strings.get(dialogueKey("completion")) }
    var doubleClickText: String? { self == .deepseekWhale ? Strings.get(dialogueKey("doubleClick")) : nil }
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
            if !previewing && pose == .thinking { return Strings.format(character.dialogueKey("running"), String(active)) }
            if !previewing && pose == .watching && media.kind == .unknown { return Strings.get(character.dialogueKey("media")) }
            return character.poseLabel(pose)
        }
        let runningKey = tasks.contains { $0.source == "DeepSeek Harness" } ? "pet.running" : "pet.running.codex"
        return previewing ? Strings.get("pet.preview") : pose == .thinking ? Strings.format(runningKey, String(active)) : pose.label
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
        react(pose, text: Strings.format("pet.preview.detail", character.poseLabel(pose)), seconds: 8, preview: true)
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
