import AppKit
import SwiftUI

@MainActor final class MootWindowController: NSWindowController, NSWindowDelegate {
    static private var sharedController: MootWindowController?
    let model: MootModel
    init(perch: PerchModel, pet: PetModel) {
        model = MootModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // Process-only visual verification; never changes the user's system appearance.
        if let index = CommandLine.arguments.firstIndex(of: "--moot-appearance"), CommandLine.arguments.indices.contains(index + 1) {
            window.appearance = NSAppearance(named: CommandLine.arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        window.title = "Moot — Perch"; window.minSize = NSSize(width: 760, height: 540); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; model.window = window
        window.contentViewController = FirstMouseHostingController(rootView: MootRootView(model: model, perch: perch, pet: pet))
        window.center(); window.setFrameAutosaveName("MootWindow")
    }
    func windowWillClose(_ notification: Notification) { model.windowVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { model.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowVisible = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func show(perch: PerchModel, pet: PetModel, section: MootSection = .capabilities) {
        if sharedController == nil { sharedController = MootWindowController(perch: perch, pet: pet) }
        guard let controller = sharedController else { return }
        controller.model.windowVisible = true; controller.model.section = section; controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true); controller.window?.makeKeyAndOrderFront(nil)
        controller.model.perform { try await controller.model.reload(loadConfig: !controller.model.hasLoadedConfiguration) }
    }
}
