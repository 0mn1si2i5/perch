import AppKit
import PerchCore

final class SpriteAtlas {
    let sprites: [NSImage]
    let cgSprites: [CGImage]
    init?(url: URL) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var frames: [NSImage] = []
        var cgFrames: [CGImage] = []
        // The generated sheet's pose boundary is 449px from its top at 887px height.
        let split = Int((Double(cg.height) * 449 / 887).rounded())
        for index in 0..<8 {
            let x = Int(Double(index % 4) * Double(cg.width) / 4)
            let right = Int(Double(index % 4 + 1) * Double(cg.width) / 4)
            let y = index < 4 ? 0 : split
            let h = index < 4 ? split : cg.height - split
            guard let frame = cg.cropping(to: CGRect(x: x, y: y, width: right - x, height: h)) else { return nil }
            frames.append(NSImage(cgImage: frame, size: NSSize(width: right - x, height: h)))
            cgFrames.append(frame)
        }
        sprites = frames
        cgSprites = cgFrames
    }
}

final class PetView: NSView {
    let model: PetModel
    let atlas: SpriteAtlas
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var animation: Timer?
    private var mouseAnchor = NSPoint.zero
    private var windowAnchor = NSPoint.zero
    private var dragging = false
    private var clickGeneration = 0
    private var hovering = false
    private let spriteLayer = CALayer()
    private let nativeOrb = NSVisualEffectView()
    private let nativeIcon = NSImageView()
    private var lastPose: PetPose?
    private var lastQuiet: Bool?

    init(model: PetModel, atlas: SpriteAtlas) {
        self.model = model; self.atlas = atlas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(spriteLayer)
        nativeOrb.material = .popover
        nativeOrb.blendingMode = .behindWindow
        nativeOrb.state = .active
        nativeOrb.wantsLayer = true
        nativeOrb.layer?.cornerRadius = 22
        nativeOrb.layer?.masksToBounds = true
        nativeOrb.layer?.borderWidth = 0.5
        nativeIcon.image = MenuBarIcon.make()
        nativeIcon.imageScaling = .scaleProportionallyUpOrDown
        nativeOrb.addSubview(nativeIcon)
        addSubview(nativeOrb)
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pox 桌宠")
        setAccessibilityHelp("单击查看 Codex 任务，双击打开 Codex，拖动移动，右键打开菜单")
    }

    func setAnimating(_ enabled: Bool) {
        animation?.invalidate()
        animation = nil
        spriteLayer.removeAllAnimations()
        lastPose = nil
        refreshAppearance()
        if !enabled || model.character == .native {
            window?.ignoresMouseEvents = false
            return
        }
        animation = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let window = self.window, window.isVisible else { return }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let hover = self.petRect.insetBy(dx: 4, dy: -12).contains(point)
            if hover != self.hovering { self.hovering = hover; self.needsDisplay = true }
            window.ignoresMouseEvents = !self.hovering && !self.dragging
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animation?.invalidate() }

    var petRect: NSRect {
        if model.character == .native {
            return NSRect(x: (bounds.width - 44) / 2, y: (bounds.height - 44) / 2, width: 44, height: 44)
        }
        return NSRect(x: (bounds.width - model.petSize) / 2, y: 30, width: model.petSize, height: model.petSize)
    }

    override func layout() { super.layout(); refreshAppearance() }

    func refreshAppearance() {
        let native = model.character == .native
        nativeOrb.isHidden = !native
        spriteLayer.isHidden = native
        setAccessibilityLabel(model.character.title)
        setAccessibilityHelp("单击打开 Perch 面板，拖动移动，右键打开菜单")
        if native {
            nativeOrb.frame = petRect
            nativeOrb.layer?.borderColor = NSColor.separatorColor.cgColor
            nativeIcon.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
            spriteLayer.removeAllAnimations()
            needsDisplay = true
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteLayer.frame = petRect
        spriteLayer.contents = atlas.cgSprites[model.pose.rawValue]
        CATransaction.commit()
        if lastPose != model.pose || lastQuiet != model.quiet {
            spriteLayer.removeAllAnimations()
            lastPose = model.pose; lastQuiet = model.quiet
            if model.enabled && model.visible && !model.quiet {
                let bob = CABasicAnimation(keyPath: "transform.translation.y")
                bob.fromValue = 0; bob.toValue = model.pose == .listening ? 4 : 2
                bob.duration = model.pose == .listening ? 0.4 : 1.8
                bob.autoreverses = true; bob.repeatCount = .infinity
                bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                spriteLayer.add(bob, forKey: "breathing")
                if model.pose == .listening || model.pose == .lifted {
                    let sway = CABasicAnimation(keyPath: "transform.rotation.z")
                    sway.fromValue = -0.035; sway.toValue = 0.035
                    sway.duration = model.pose == .lifted ? 0.2 : 0.6
                    sway.autoreverses = true; sway.repeatCount = .infinity
                    sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    spriteLayer.add(sway, forKey: "sway")
                }
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard model.character == .pox else { return }
        let pose = model.pose
        let rect = petRect

        if hovering || pose != .idle {
            let active = model.tasks.filter { $0.status == .running }.count
            let label = model.previewing ? "动作预览" : pose == .thinking ? "Codex · \(active) 个任务" : pose.label
            drawPill(label, y: 4)
        }
        if let text = model.bubble {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1), .paragraphStyle: paragraph
            ]
            let maxWidth = min(bounds.width - 16, 250)
            let string = NSAttributedString(string: text, attributes: attrs)
            let measured = string.boundingRect(with: NSSize(width: maxWidth - 24, height: 70), options: [.usesLineFragmentOrigin])
            let bubble = NSRect(x: (bounds.width - maxWidth) / 2, y: rect.maxY + 8, width: maxWidth, height: ceil(measured.height) + 22)
            NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 13, yRadius: 13).fill()
            string.draw(in: bubble.insetBy(dx: 12, dy: 11))
        }
    }

    private func drawPill(_ text: String, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                       .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)]
        let width = (text as NSString).size(withAttributes: attributes).width + 22
        let rect = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 21)
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 11, y: rect.minY + 4), withAttributes: attributes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func mouseDown(with event: NSEvent) {
        mouseAnchor = NSEvent.mouseLocation; windowAnchor = window?.frame.origin ?? .zero
        dragging = false; clickGeneration += 1
    }
    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseAnchor.x, dy = current.y - mouseAnchor.y
        if !dragging && hypot(dx, dy) > 4 {
            dragging = true; model.react(.lifted, seconds: 3600)
        }
        if dragging { window?.setFrameOrigin(NSPoint(x: windowAnchor.x + dx, y: windowAnchor.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            if let window { clampToScreen(window); savePosition(window) }
            model.react(.confused, text: "好家伙，搬家了。", seconds: 2)
        } else if event.clickCount >= 2 {
            onDoubleClick?(); model.react(.salute, seconds: 2)
        } else {
            let token = clickGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                guard let self, token == self.clickGeneration else { return }; self.onClick?()
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    func clampToScreen(_ window: NSWindow) {
        let frame = window.frame
        guard let screen = NSScreen.screens.max(by: {
            let a = $0.visibleFrame.intersection(frame), b = $1.visibleFrame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }) else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                                      y: min(max(frame.minY, visible.minY), visible.maxY - frame.height)))
    }
    func savePosition(_ window: NSWindow) {
        UserDefaults.standard.set(window.frame.origin.x, forKey: "petX")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "petY")
    }
}
