import AppKit
import Testing
@testable import PureMouseMenu

/// Which glyph the status item shows for which state: shape for paused, opacity for off, never
/// colour (docs/ui-design.md, Status menu and menu bar icon).
@MainActor
struct StatusIconTests {
    @Test func theDecisionForEachState() {
        #expect(StatusIcon.look(daemonRunning: true, paused: false) == .running)
        #expect(StatusIcon.look(daemonRunning: true, paused: true) == .paused)
        #expect(StatusIcon.look(daemonRunning: false, paused: false) == .off)
        // Off wins: a daemon that is not running is not paused, whatever its last status said.
        #expect(StatusIcon.look(daemonRunning: false, paused: true) == .off)
    }

    @Test func pausedIsSlashedAtFullOpacityAndOffIsDimmedWithoutASlash() {
        #expect(StatusIcon.Look.paused.slashed && StatusIcon.Look.paused.opacity == 1)
        #expect(!StatusIcon.Look.off.slashed && StatusIcon.Look.off.opacity == 0.4)
        #expect(!StatusIcon.Look.running.slashed && StatusIcon.Look.running.opacity == 1)
    }

    @Test func everyLookDrawsATemplateOfTheSameSize() {
        let sizes = [StatusIcon.Look.running, .paused, .off].map { StatusIcon.image(look: $0, badge: .none).size }
        #expect(Set(sizes.map(\.width)).count == 1 && Set(sizes.map(\.height)).count == 1)
        #expect([StatusIcon.Look.running, .paused, .off].allSatisfy { StatusIcon.image(look: $0, badge: .attention).isTemplate })
    }

    @Test func theDevHookWritesEachLookAtBothScales() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        DevHooks.writeIcons(to: directory)
        for name in ["running", "paused", "off", "attention"] {
            for scale in 1...2 {
                let data = try Data(contentsOf: directory.appending(path: "\(name)@\(scale)x.png"))
                let rep = try #require(NSBitmapImageRep(data: data))
                #expect(rep.pixelsWide % scale == 0 && rep.pixelsWide > 0)
            }
        }
        // The paused PNG differs from the running one: the slash is drawn.
        let running = try Data(contentsOf: directory.appending(path: "running@2x.png"))
        let paused = try Data(contentsOf: directory.appending(path: "paused@2x.png"))
        #expect(running != paused)
    }

    @Test func theSlashSitsOnWholeOrHalfPointsAndClearOfTheBadgeRing() {
        let size = NSSize(width: 18, height: 18)
        let (start, end) = StatusIcon.slashEnds(in: size)
        for value in [start.x, start.y, end.x, end.y] { #expect(value * 2 == (value * 2).rounded()) }
        // A stroke of whole points keeps its weight at 1x.
        #expect(StatusIcon.slashWidth == StatusIcon.slashWidth.rounded() && StatusIcon.slashGap == StatusIcon.slashGap.rounded())
        // The cut (the stroke and its gaps) stays 1 pt from the ring: radius 5 about (13.5, 4.5).
        let centre = NSPoint(x: 13.5, y: 4.5)
        let (dx, dy) = (end.x - start.x, end.y - start.y)
        let t = max(0, min(1, ((centre.x - start.x) * dx + (centre.y - start.y) * dy) / (dx * dx + dy * dy)))
        let distance = hypot(start.x + t * dx - centre.x, start.y + t * dy - centre.y)
        let reach = StatusIcon.slashWidth / 2 + StatusIcon.slashGap
        #expect(distance - reach - 5 >= 1)
    }
}
