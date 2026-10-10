import AppKit

/// Three birds on one perch: one per account, the middle one stands out. Template image, so macOS tints it.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            func bird(body: NSPoint, radius: CGFloat, head: NSPoint, headRadius: CGFloat, alpha: CGFloat) {
                NSColor.black.withAlphaComponent(alpha).setFill()
                // One path per bird so the overlap of body and head is not painted twice.
                let shape = NSBezierPath(ovalIn: NSRect(x: body.x - radius, y: body.y - radius, width: radius * 2, height: radius * 2))
                shape.append(NSBezierPath(ovalIn: NSRect(x: head.x - headRadius, y: head.y - headRadius,
                                                         width: headRadius * 2, height: headRadius * 2)))
                shape.windingRule = .nonZero
                shape.fill()
            }
            bird(body: NSPoint(x: 4, y: 11), radius: 2.2, head: NSPoint(x: 5.3, y: 8.6), headRadius: 1.2, alpha: 0.55)
            bird(body: NSPoint(x: 9, y: 10.4), radius: 2.8, head: NSPoint(x: 10.6, y: 7.4), headRadius: 1.5, alpha: 1)
            bird(body: NSPoint(x: 14, y: 11), radius: 2.2, head: NSPoint(x: 15.3, y: 8.6), headRadius: 1.2, alpha: 0.55)
            let perch = NSBezierPath()
            perch.move(to: NSPoint(x: 1.5, y: 14)); perch.line(to: NSPoint(x: 16.5, y: 14))
            perch.lineWidth = 1.4; perch.lineCapStyle = .round
            NSColor.black.setStroke(); perch.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Perch"
        return image
    }
}
