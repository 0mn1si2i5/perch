import AppKit
import SwiftUI
import PerchCore

final class PetWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let pet = PetModel()
    private let perch = PerchModel()
    private var panel: PetWindow!
    private var petView: PetView!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Closes the panel on any click in another app. `.transient` alone misses these when Perch never became active.
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var popoverAnchor: PetWindow?
    private var popoverPetOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let url = Bundle.main.url(forResource: "pox-atlas", withExtension: "png"),
              let atlas = SpriteAtlas(url: url) else {
            let alert = NSAlert(); alert.messageText = "Pox 的角色素材没有找到"
            alert.informativeText = "请通过项目中的 build_and_run.sh 重新构建完整应用。"
            alert.runModal(); NSApp.terminate(nil); return
        }
        NSApp.applicationIconImage = atlas.sprites[0]
        panel = PetWindow(contentRect: NSRect(origin: .zero, size: windowSize()),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pox 桌宠"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(petWindowDidMove),
                                               name: NSWindow.didMoveNotification, object: panel)
        petView = PetView(model: pet, atlas: atlas)
        panel.contentView = petView
        petView.onClick = { [weak self] in self?.togglePopover(fromPet: true) }
        petView.onDoubleClick = { [weak self] in self?.popover.close(); self?.perch.openBusiestAccount() }
        petView.onMenu = { [weak self] event in
            guard let self else { return }; self.popover.close()
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self.petView)
        }
        pet.changed = { [weak self] in self?.petView.refreshAppearance() }
        pet.resize = { [weak self] in
            guard let self else { return }; self.panel.setContentSize(self.windowSize()); self.petView.clampToScreen(self.panel)
        }
        if UserDefaults.standard.object(forKey: "petX") != nil {
            panel.setFrameOrigin(NSPoint(x: UserDefaults.standard.double(forKey: "petX"), y: UserDefaults.standard.double(forKey: "petY")))
            petView.clampToScreen(panel)
        } else { resetPosition() }

        // Own dismissal explicitly: transient popovers can dismiss during their first focus/size change.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let hosting = FirstMouseHostingController(rootView: PerchPanel(perch: perch, pet: pet))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        PerchNotifications.shared.configure { [weak self] in self?.showPanel() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        perch.onTasks = { [weak self] tasks, completed in self?.pet.update(tasks: tasks, completed: completed) }
        pet.configurationChanged = { [weak self] in self?.syncCompanion() }
        syncCompanion()
        pet.start()
        perch.start()
    }

    private func windowSize() -> NSSize {
        pet.character == .native ? NSSize(width: 56, height: 56)
            : NSSize(width: max(280, pet.petSize + 30), height: pet.petSize + 125)
    }

    private func syncCompanion() {
        panel.setContentSize(windowSize())
        panel.hasShadow = pet.character == .native
        panel.title = pet.character.title
        petView.clampToScreen(panel)
        if pet.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        petView.setAnimating(pet.visible)
        popover.contentViewController?.view.window?.appearance = pet.usesCharacterTheme ? NSAppearance(named: .darkAqua) : nil
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.close()
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover(fromPet: false)
        }
    }

    private func togglePopover(fromPet: Bool) {
        if popover.isShown { popover.close(); return }
        // Activate the accessory app and make its popover key before the first context menu tracks.
        NSApp.activate(ignoringOtherApps: true)
        if fromPet && panel.isVisible {
            // Follow movement explicitly; a child window would also hide the popover with the pet.
            let rect = panel.convertToScreen(petView.convert(petView.petRect, to: nil))
            if popoverAnchor == nil {
                let anchor = PetWindow(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                anchor.isOpaque = false
                anchor.backgroundColor = .clear
                anchor.hasShadow = false
                anchor.ignoresMouseEvents = true
                anchor.level = .floating
                anchor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                anchor.isReleasedWhenClosed = false
                anchor.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
                popoverAnchor = anchor
            }
            if let anchor = popoverAnchor, let view = anchor.contentView {
                anchor.setFrame(rect, display: false)
                popoverPetOrigin = panel.frame.origin
                anchor.orderFrontRegardless()
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
            }
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        focusPopover()
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.popover.isShown, event.keyCode == 53,
                      event.window == self.popover.contentViewController?.view.window else { return event }
                self.popover.close()
                return nil
            }
        }
        perch.poll()
        if popover.isShown { perch.panelOpened() }
        if popover.isShown && outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] _ in
                guard let self, self.popover.isShown else { return }
                // Activation is asynchronous. The first click may reach the global monitor
                // while the popover is still becoming key; an inside click is never dismissal.
                let point = NSEvent.mouseLocation
                guard !PanelClickPolicy.isInside(point, frame: self.popover.contentViewController?.view.window?.frame) else { return }
                self.popover.close()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverPetOrigin = nil
        popoverAnchor?.orderOut(nil)
        perch.panelClosed()
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
    }

    @objc private func petWindowDidMove(_ notification: Notification) {
        guard let previous = popoverPetOrigin, let anchor = popoverAnchor,
              popover.isShown else { return }
        let current = panel.frame.origin
        popoverPetOrigin = current
        anchor.setFrameOrigin(NSPoint(x: anchor.frame.minX + current.x - previous.x,
                                      y: anchor.frame.minY + current.y - previous.y))
    }

    func popoverDidShow(_ notification: Notification) { focusPopover() }

    func applicationDidBecomeActive(_ notification: Notification) { focusPopover() }

    private func focusPopover() {
        guard popover.isShown else { return }
        guard let window = popover.contentViewController?.view.window else { return }
        (window as? NSPanel)?.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = pet.usesCharacterTheme ? NSAppearance(named: .darkAqua) : nil
        if !window.isKeyWindow { window.makeKey() }
    }

    @objc private func showPanel() {
        if popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            focusPopover()
        } else {
            togglePopover(fromPet: false)
        }
    }

    @objc private func togglePet() {
        pet.setVisible(!pet.visible)
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 28, y: screen.visibleFrame.minY + 24))
        petView?.savePosition(panel)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Perch")
        let open = NSMenuItem(title: "打开面板", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if pet.enabled {
            for (title, action) in [
                (pet.visible ? "隐藏桌宠" : "显示桌宠", #selector(togglePet)),
                ("恢复桌宠位置", #selector(resetPosition))
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "退出 Perch", action: #selector(quit), keyEquivalent: "q")
        item.target = self; menu.addItem(item)
        return menu
    }
}

@main
enum PerchMain {
    static func main() {
        PreferenceMigration.run(from: UserDefaults(suiteName: PreferenceMigration.legacyDomain), to: .standard)
        if CommandLine.arguments.contains("--diagnose") { Diagnose.run(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
