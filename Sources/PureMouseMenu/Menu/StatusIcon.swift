import AppKit

/// The menu bar glyph: `MenuBarIcon.pdf` from the bundle as a template, with its state shown by
/// shape and opacity (never colour): a diagonal slash through it while paused, dimmed while off,
/// and a small badge when something needs attention or the battery is at 10% or less.
@MainActor
enum StatusIcon {
    enum Badge { case none, attention, battery }

    /// How the glyph itself looks. Paused is a different shape at full opacity; off is the plain
    /// shape dimmed, so a paused PureMouse never reads as one that is not running.
    enum Look: Equatable {
        case running, paused, off

        var opacity: CGFloat { self == .off ? 0.4 : 1 }
        var slashed: Bool { self == .paused }
    }

    /// Off wins: a daemon that is not running is not paused, whatever the last status said.
    nonisolated static func look(daemonRunning: Bool, paused: Bool) -> Look {
        daemonRunning ? (paused ? .paused : .running) : .off
    }

    private static let bundled: NSImage? = {
        var url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf")
        #if DEBUG
        // `swift run` from the repository.
        if url == nil { url = URL(fileURLWithPath: "assets/MenuBarIcon.pdf") }
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
    }()
    /// A `swift build` binary has no bundle resources.
    private static let glyph = bundled ?? NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)!

    /// The template is drawn at its own size (18 × 18 pt, padding included), like system extras.
    private static var glyphHeight: CGFloat { bundled != nil ? glyph.size.height : 16 }

    static func image(look: Look, badge: Badge) -> NSImage {
        let aspect = glyph.size.width / max(glyph.size.height, 1)
        let glyphSize = NSSize(width: (glyphHeight * aspect).rounded(), height: glyphHeight)
        // The bundled template has room for the badge in its padding; the fallback symbol does not.
        let overhang: CGFloat = badge == .none || bundled != nil ? 0 : 4
        let size = NSSize(width: glyphSize.width + overhang, height: glyphHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(origin: .zero, size: glyphSize), from: .zero, operation: .sourceOver,
                       fraction: look.opacity)
            if look.slashed, let context = NSGraphicsContext.current?.cgContext { slash(in: glyphSize, context) }
            guard badge != .none, let context = NSGraphicsContext.current?.cgContext else { return true }
            let centre = NSPoint(x: size.width - 4.5, y: 4.5)
            // Knock a ring out of the glyph so the badge reads as separate.
            context.setBlendMode(.clear)
            NSBezierPath(ovalIn: NSRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)).fill()
            context.setBlendMode(.normal)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch badge {
            case .attention:
                NSBezierPath(ovalIn: NSRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)).fill()
                context.setBlendMode(.clear)
                NSBezierPath(roundedRect: NSRect(x: centre.x - 0.6, y: centre.y - 0.4, width: 1.2, height: 3),
                             xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(ovalIn: NSRect(x: centre.x - 0.65, y: centre.y - 2.6, width: 1.3, height: 1.3)).fill()
                context.setBlendMode(.normal)
            case .battery:
                let body = NSBezierPath(roundedRect: NSRect(x: centre.x - 4, y: centre.y - 2.25, width: 7, height: 4.5),
                                        xRadius: 1, yRadius: 1)
                body.lineWidth = 1
                body.stroke()
                NSBezierPath(rect: NSRect(x: centre.x + 3, y: centre.y - 1, width: 1, height: 2)).fill()
                NSBezierPath(rect: NSRect(x: centre.x - 3, y: centre.y - 1.25, width: 1.2, height: 2.5)).fill()
            case .none:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A "/" from the bottom left to the top right (the badge sits at the bottom right): a gap cut
    /// through the glyph with the line left standing in it, so it reads over the mouse's body.
    private static func slash(in size: NSSize, _ context: CGContext) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: size.width * 0.2, y: size.height * 0.15))
        line.line(to: NSPoint(x: size.width * 0.8, y: size.height * 0.85))
        line.lineCapStyle = .round
        context.setBlendMode(.clear)
        line.lineWidth = 4
        line.stroke()
        context.setBlendMode(.normal)
        NSColor.black.setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }

    /// The glyph for the menu's device header, sized like the mockup (13 × 21 pt in a 22 pt row
    /// is too tall for a menu; 11 pt high matches the menu's text).
    static func headerImage(height: CGFloat = 16) -> NSImage {
        let aspect = glyph.size.width / max(glyph.size.height, 1)
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

