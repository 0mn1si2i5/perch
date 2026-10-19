import AppKit
import Combine
import SwiftUI
import PerchCore

/// Polls the codex-delegate runs root and publishes the recent runs.
final class DelegateMonitor: ObservableObject {
    @Published private(set) var runs: [DelegateRun] = []
    @Published var selectedID: String?
    /// Called on the main thread for a running run that appeared after the first scan.
    var onNewRun: ((DelegateRun) -> Void)?
    var fast = false { didSet { if fast != oldValue { schedule() } } }

    private let reader = DelegateRunReader()
    private let queue = DispatchQueue(label: "perch.delegate-runs", qos: .utility)
    private var timer: Timer?
    private var known: Set<String>?
    private var reading = false

    var selected: DelegateRun? { runs.first { $0.id == selectedID } ?? runs.first }
    var runningCount: Int { runs.filter(\.isRunning).count }

    func start() { poll(); schedule() }

    private func schedule() {
        timer?.invalidate()
        // One second while the panel is open, three while hidden (still needed to pop it up for new runs).
        timer = Timer.scheduledTimer(withTimeInterval: fast ? 1 : 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        guard !reading else { return }
        reading = true
        queue.async { [weak self] in
            guard let self else { return }
            let runs = self.reader.read()
            DispatchQueue.main.async { self.apply(runs) }
        }
    }

    private func apply(_ runs: [DelegateRun]) {
        reading = false
        if runs != self.runs { self.runs = runs }
        let ids = Set(runs.map(\.id))
        if let known {
            for run in runs where run.isRunning && !known.contains(run.id) { onNewRun?(run) }
        }
        known = (known ?? []).union(ids)
    }
}

final class DelegatePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A small floating panel for codex-delegate runs. It never activates Perch, so it can stay on screen
/// next to the conversation that started the run.
final class DelegatePanelController: NSObject, NSWindowDelegate {
    static let visibleKey = "delegatePanelVisible"
    static let autoShowKey = "delegatePanelAutoShow"
    static let expandedKey = "delegatePanelExpanded"

    let monitor = DelegateMonitor()
    private var window: DelegatePanelWindow!
    private var cancellables: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard

    var isVisible: Bool { window.isVisible }
    var autoShow: Bool {
        get { defaults.object(forKey: Self.autoShowKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoShowKey) }
    }

    func start() {
        window = DelegatePanelWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                                     styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                                     backing: .buffered, defer: false)
        window.title = "子代理"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = DelegatePanelView(monitor: monitor, close: { [weak self] in self?.hide() },
                                     expandedChanged: { [weak self] in self?.fit(animated: true) })
        window.contentView = FirstMouseHostingView(rootView: view)
        if !window.setFrameUsingName("CodexDelegatePanel") { placeDefault() }
        window.setFrameAutosaveName("CodexDelegatePanel")
        fit(animated: false)

        monitor.$runs.receive(on: RunLoop.main).sink { [weak self] _ in self?.fit(animated: false) }.store(in: &cancellables)
        monitor.onNewRun = { [weak self] run in
            guard let self, self.autoShow else { return }
            self.monitor.selectedID = run.id
            self.show()
        }
        monitor.start()
        if defaults.bool(forKey: Self.visibleKey) { show() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        window.orderFrontRegardless()
        defaults.set(true, forKey: Self.visibleKey)
        monitor.fast = true
        monitor.poll()
    }

    func hide() {
        window.orderOut(nil)
        defaults.set(false, forKey: Self.visibleKey)
        monitor.fast = false
    }

    func windowWillClose(_ notification: Notification) { hide() }

    private func placeDefault() {
        guard let screen = NSScreen.main else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24))
    }

    /// Resize to the view's layout while keeping the top edge in place.
    private func fit(animated: Bool) {
        let expanded = defaults.bool(forKey: Self.expandedKey)
        let size = DelegatePanelLayout.size(expanded: expanded, runCount: monitor.runs.count)
        var frame = window.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen ?? NSScreen.main {
            frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}
