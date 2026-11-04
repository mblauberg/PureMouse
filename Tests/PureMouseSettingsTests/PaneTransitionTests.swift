import AppKit
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The Settings window's one transition (`PaneTransition`): when it animates, that it alone moves
// the frame, and that a page change still lands on the pane's measured height. The animation
// itself is checked on screen with the filmstrip hook (docs/development.md).

@MainActor @Suite struct PaneTransitionStyleTests {
    @Test func aHiddenWindowOrReduceMotionChangesAtOnce() {
        #expect(PaneTransition.style(visible: false, reduceMotion: false, resizeTime: 0.3) == .instant)
        #expect(PaneTransition.style(visible: true, reduceMotion: true, resizeTime: 0.3) == .instant)
        #expect(PaneTransition.style(visible: false, reduceMotion: true, resizeTime: 0.3) == .instant)
    }

    @Test func theLengthIsAppKitsResizeTimeWithinBounds() {
        let bounds = PaneTransition.durations
        #expect(PaneTransition.style(visible: true, reduceMotion: false, resizeTime: 0) == .animated(bounds.lowerBound),
                "a fade with no height change is still seen")
        #expect(PaneTransition.style(visible: true, reduceMotion: false, resizeTime: 0.25) == .animated(0.25))
        #expect(PaneTransition.style(visible: true, reduceMotion: false, resizeTime: 2) == .animated(bounds.upperBound))
    }

    @Test func onlyThePaneTransitionMovesTheWindowFrame() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/PureMouseSettingsUI")
        let files = try FileManager.default.contentsOfDirectory(at: ui, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files where file.lastPathComponent != "PaneTransition.swift" {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains("setFrame("), "\(file.lastPathComponent) sizes the window")
            #expect(!code.contains("setContentSize("), "\(file.lastPathComponent) sizes the window")
            #expect(!code.contains(".crossfade"), "\(file.lastPathComponent) adds a second cross-fade")
        }
        // NSTabViewController's own handler sizes the window to the pane's preferred size.
        let window = try String(contentsOf: ui.appending(path: "SettingsWindow.swift"), encoding: .utf8)
        let start = try #require(window.range(of: "final class SettingsTabs"))
        let tabs = window[start.lowerBound...]
        let body = tabs[..<(tabs.range(of: "\n}\n")?.lowerBound ?? tabs.endIndex)]
        #expect(body.contains("override func preferredContentSizeDidChange"))
        #expect(!body.contains("super.preferredContentSizeDidChange"), "the tab controller sizes the window too")
    }
}

@MainActor @Suite struct PaneTransitionTests {
    /// A hidden window with a content view, and a transition over it whose target is `height` tall.
    @MainActor private final class Rig {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let container = NSView()
        var height: CGFloat = 300
        var measured = 0
        lazy var transition = PaneTransition(host: window.contentView!) { [unowned self] in
            measured += 1
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 600, height: height))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            return frame
        } container: { [unowned self] in container }

        init() {
            window.isReleasedWhenClosed = false
            container.frame = window.contentView!.bounds
            window.contentView!.addSubview(container)
        }
    }

    @Test func aHiddenWindowTakesTheNewHeightAtOnceWithNoSnapshot() {
        let rig = Rig()
        rig.transition.reduceMotion = { false }
        let top = rig.window.frame.maxY
        let views = rig.window.contentView!.subviews.count
        rig.transition.change { rig.height = 450 }
        #expect(rig.window.contentLayoutRect.height == 450)
        #expect(rig.window.frame.maxY == top, "the top edge stays")
        #expect(!rig.transition.isAnimating)
        #expect(rig.window.contentView!.subviews.count == views, "no snapshot left over the page")
        #expect(rig.container.alphaValue == 1)
    }

    @Test func aChangeMeasuresOnceWhenItEndsAndNestedChangesJoinIt() {
        let rig = Rig()
        rig.transition.change {
            #expect(rig.transition.isChanging)
            rig.transition.change { rig.height = 420 }
            rig.transition.fit()
            #expect(rig.measured == 0, "nothing measures or moves the frame mid-change")
        }
        #expect(!rig.transition.isChanging)
        #expect(rig.measured == 1)
        #expect(rig.window.contentLayoutRect.height == 420)
    }

    @Test func growthInAPageFitsTheWindow() {
        let rig = Rig()
        rig.height = 360
        rig.transition.fit()
        #expect(rig.window.contentLayoutRect.height == 360)
        #expect(!rig.transition.isAnimating)
    }

    @Test func nothingToMeasureLeavesTheFrame() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let frame = window.frame
        let transition = PaneTransition(host: window.contentView!) { nil } container: { nil }
        transition.change {}
        transition.fit()
        #expect(window.frame == frame)
    }

    /// Settings' tabs in a hidden window: each tab's plain pane asks for its own height.
    private func tabs(heights: [SettingsTab: CGFloat]) -> (SettingsTabs, NSWindow) {
        let tabs = SettingsTabs()
        tabs.transitionOptions = []
        for tab in SettingsTab.shown {
            let pane = NSViewController()
            pane.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
            pane.preferredContentSize = NSSize(width: 600, height: heights[tab] ?? 300)
            let item = NSTabViewItem(viewController: pane)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        tabs.pageTransition.reduceMotion = { false }
        return (tabs, window)
    }

    @Test func aTabChangeInAHiddenWindowLandsOnThePanesHeight() {
        let (tabs, window) = tabs(heights: [.general: 320, .mouse: 480, .apps: 240, .about: 260])
        let steps: [(SettingsPane, CGFloat)] = [(.tab(.apps), 240), (.tab(.general), 320), (.mouse(.buttons), 480), (.tab(.about), 260)]
        for (pane, height) in steps {
            tabs.open(pane)
            #expect(window.contentLayoutRect.height == height, "\(pane)")
            #expect(!tabs.pageTransition.isAnimating, "\(pane)")
        }
    }

    @Test func aTallPaneLandsAtTheCap() {
        let (tabs, window) = tabs(heights: [.apps: 2400])
        tabs.open(.tab(.apps))
        #expect(window.contentLayoutRect.height <= SettingsWindowController.maxContentHeight)
        #expect(window.contentLayoutRect.height == LazyPane.maxHeight(on: window.screen))
    }
}
