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

    /// The slash's stroke: a whole number of points, so it keeps its weight at 1x, with a gap of 1 pt
    /// cut through the glyph on its upper-left side only, as the system's `.slash` symbols have it.
    static let slashWidth: CGFloat = 2
    static let slashGap: CGFloat = 1

    /// The slash's ends in an 18 pt glyph, at whole or half points: from the bottom left to the top
    /// right (the badge sits at the bottom right), on the line y = x + 1, just above the glyph's
    /// centre. The gap is on the far side from the badge, so only half the stroke (1 pt) reaches
    /// towards the badge's ring (a circle of radius 5 about (13.5, 4.5)): the line is 7.07 pt from the
    /// ring's centre, which leaves just over 1 pt clear.
    static func slashEnds(in size: NSSize) -> (NSPoint, NSPoint) {
        func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: snap(size.width * x / 18), y: snap(size.height * y / 18))
        }
        return (point(3.5, 4.5), point(13.5, 14.5))
    }

    /// A "/" through the glyph: a gap cut through it beside the line, on the upper-left side, then the
    /// line, so it reads over the mouse's body without the stripes a gap on both sides makes at 1x.
    private static func slash(in size: NSSize, _ context: CGContext) {
        let (start, end) = slashEnds(in: size)
        let length = max(hypot(end.x - start.x, end.y - start.y), 1)
        // The unit normal towards the upper left.
        let normal = NSPoint(x: -(end.y - start.y) / length, y: (end.x - start.x) / length)
        let shift = slashGap / 2
        let cut = NSBezierPath()
        cut.move(to: NSPoint(x: start.x + normal.x * shift, y: start.y + normal.y * shift))
        cut.line(to: NSPoint(x: end.x + normal.x * shift, y: end.y + normal.y * shift))
        cut.lineCapStyle = .round
        cut.lineWidth = slashWidth + slashGap
        context.setBlendMode(.clear)
        cut.stroke()
        context.setBlendMode(.normal)
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineCapStyle = .round
        line.lineWidth = slashWidth
        NSColor.black.setStroke()
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

