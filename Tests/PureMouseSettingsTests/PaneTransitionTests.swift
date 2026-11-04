import AppKit
import PureMouseAppSupport
import PureMouseKit
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
        var onMeasure: (() -> Void)?
        var time: TimeInterval = 100
        var visible = true
        var reduced = false
        var durations: [TimeInterval] = []
        var completions: [@MainActor @Sendable () -> Void] = []

        func controlledAnimation() {
            transition.isVisible = { [unowned self] _ in visible }
            transition.reduceMotion = { [unowned self] in reduced }
            transition.now = { [unowned self] in time }
            transition.animateGroup = { [unowned self] duration, changes, completion in
                durations.append(duration)
                changes()
                completions.append(completion)
            }
        }
        lazy var transition = PaneTransition(host: window.contentView!) { [unowned self] in
            measured += 1
            let update = onMeasure
            onMeasure = nil
            update?()
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 600, height: height))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            return frame
        } container: { [unowned self] in container }

        init() {
            window.isReleasedWhenClosed = false
            container.wantsLayer = true
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

    @Test func navigationConsumedDuringMeasurementJoinsTheOriginalChange() {
        let rig = Rig()
        rig.controlledAnimation()
        rig.onMeasure = {
            #expect(rig.transition.isChanging)
            rig.transition.change { rig.height = 460 }
        }
        rig.transition.change { rig.height = 450 }
        #expect(rig.measured == 1)
        #expect(rig.durations.count == 2, "one fade and one frame group, with no second flight")
        #expect(!rig.transition.isChanging)
        rig.transition.cancel()
        #expect(rig.window.contentLayoutRect.height == 460)
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

    @Test func incomingPageIsHiddenDuringSwapButStillAcceptsInput() throws {
        let rig = Rig()
        rig.controlledAnimation()
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 100, height: 30))
        rig.container.addSubview(button)
        rig.transition.change {
            #expect(rig.container.alphaValue == 1)
            #expect(rig.container.layer?.opacity == 0, "no incoming ink before the fade is attached")
            #expect(rig.container.hitTest(NSPoint(x: 20, y: 20)) === button)
            CATransaction.flush() // Even a layout-triggered commit during the swap stays hidden.
            #expect(rig.container.layer?.opacity == 0)
            rig.height = 450
        }
        #expect(rig.container.alphaValue == 1)
        #expect(rig.container.layer?.opacity == 1)
        let fade = try #require(rig.container.layer?.animation(forKey: "PaneTransition.fadeIn") as? CABasicAnimation)
        #expect(fade.fromValue as? Int == 0)
        #expect(fade.toValue as? Int == 1)
        #expect(fade.fillMode == .backwards, "the first frame is hidden even before the animation starts")
        #expect(fade.beginTime == rig.time)
        #expect(fade.duration == rig.durations[0])
        rig.transition.cancel()
        #expect(rig.container.layer?.opacity == 1)
        #expect(rig.container.layer?.animation(forKey: "PaneTransition.fadeIn") == nil)
    }

    @Test(arguments: [true, false]) func retargetWaitsForBothFadeAndLatestFrame(fadeFirst: Bool) throws {
        let rig = Rig()
        rig.controlledAnimation()
        rig.transition.change { rig.height = 450 }
        #expect(rig.transition.isAnimating)
        #expect(rig.container.alphaValue == 1)
        let duration = try #require(rig.durations.first)
        rig.time += duration / 2
        rig.height = 470
        rig.transition.fit()
        #expect(rig.durations.count == 3)
        #expect(abs(rig.durations[2] - duration / 2) < 0.00001)
        rig.completions[1]() // AppKit cancels the original frame animation.
        #expect(rig.transition.isAnimating)
        rig.completions[fadeFirst ? 0 : 2]()
        #expect(rig.transition.isAnimating, "the remaining visual work still owns the pins")
        rig.completions[fadeFirst ? 2 : 0]()
        #expect(!rig.transition.isAnimating)
        #expect(rig.window.contentView!.subviews.count == 1)
    }

    @Test func frameOnlyRetargetIgnoresCancelledCompletionAndKeepsPins() {
        let rig = Rig()
        rig.controlledAnimation()
        let bottom = rig.container.bottomAnchor.constraint(equalTo: rig.window.contentView!.bottomAnchor)
        bottom.isActive = true
        rig.height = 450
        rig.transition.fit()
        let pins = rig.window.contentView!.constraints.filter { $0.isActive && $0.firstAttribute == .top }
        #expect(!pins.isEmpty)
        #expect(!bottom.isActive)
        rig.time += 0.05
        rig.height = 470
        rig.transition.fit()
        #expect(rig.completions.count == 2)
        rig.completions[0]()
        #expect(rig.transition.isAnimating)
        #expect(!bottom.isActive)
        #expect(pins.allSatisfy { $0.isActive }, "the top pin survives the cancelled group's callback")
        #expect(rig.container.constraints.contains { $0.isActive && $0.firstAttribute == .height && $0.constant == 470 })
        rig.completions[1]()
        #expect(!rig.transition.isAnimating)
        #expect(bottom.isActive)
        #expect(pins.allSatisfy { !$0.isActive })
    }

    @Test func staleCompletionCannotLandANewerFlight() {
        let rig = Rig()
        rig.controlledAnimation()
        rig.transition.change { rig.height = 450 }
        rig.transition.change { rig.height = 400 }
        #expect(rig.completions.count == 4)
        rig.completions[0]()
        rig.completions[1]()
        #expect(rig.transition.isAnimating)
        #expect(rig.window.contentView!.subviews.count == 2)
        rig.completions[2]()
        rig.completions[3]()
        #expect(!rig.transition.isAnimating)
    }

    @Test func closingDuringAFlightCleansUp() {
        let rig = Rig()
        rig.controlledAnimation()
        let bottom = rig.container.bottomAnchor.constraint(equalTo: rig.window.contentView!.bottomAnchor)
        bottom.isActive = true
        rig.transition.change { rig.height = 450 }
        #expect(!bottom.isActive)
        rig.transition.cancel()
        #expect(!rig.transition.isAnimating)
        #expect(bottom.isActive)
        #expect(rig.window.contentView!.subviews.count == 1)
        #expect(rig.container.alphaValue == 1)
        rig.completions[0]()
        #expect(!rig.transition.isAnimating)
    }

    @Test(arguments: [true, false]) func policyChangeDuringFlightLandsImmediately(hidden: Bool) {
        let rig = Rig()
        rig.controlledAnimation()
        rig.transition.change { rig.height = 450 }
        rig.visible = !hidden
        rig.reduced = !hidden
        rig.height = 470
        rig.transition.fit()
        #expect(!rig.transition.isAnimating)
        #expect(rig.window.contentLayoutRect.height == 470)
        #expect(rig.window.contentView!.subviews.count == 1)
        #expect(rig.durations.count == 2)
    }

    @Test func unchangedTargetStillRechecksMotionPolicy() {
        let rig = Rig()
        rig.controlledAnimation()
        rig.transition.change { rig.height = 450 }
        rig.reduced = true
        rig.transition.fit()
        #expect(!rig.transition.isAnimating)
        #expect(rig.window.contentView!.subviews.count == 1)
        #expect(rig.durations.count == 2)
    }

    @Test func snapshotIgnoresInputAndAccessibility() throws {
        let rig = Rig()
        rig.controlledAnimation()
        rig.transition.begin()
        let snapshot = try #require(rig.window.contentView!.subviews.last as? SnapshotView)
        #expect(snapshot.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(snapshot.accessibilityIsIgnored())
        #expect(!snapshot.isAccessibilityElement())
        rig.transition.end()
        rig.transition.cancel()
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

    @Test func visibleShowActivationAndSamePageRequestsDoNotFade() {
        let (tabs, window) = tabs(heights: [.mouse: 300])
        tabs.open(.mouse(.pointer))
        defer { window.close() }
        let context = SettingsContext()
        context.tabs = tabs
        tabs.pageTransition.isVisible = { _ in true }
        var animations = 0
        tabs.pageTransition.animateGroup = { _, changes, _ in
            animations += 1
            changes()
        }
        // The navigation path used by show(nil), show(ShowRequest()), and sheet-only requests.
        context.show(nil)
        context.show(ShowRequest())
        context.show(ShowRequest(pane: .tab(.mouse)))
        context.show(ShowRequest(pane: .mouse(.pointer)))
        context.show(ShowRequest(sheet: .presets))
        #expect(animations == 0)
        #expect(!tabs.pageTransition.isAnimating)
        context.show(ShowRequest(pane: .mouse(.buttons)))
        #expect(animations == 2, "a different segment still transitions")
        context.show(nil)
        context.show(ShowRequest(pane: .mouse(.buttons)))
        #expect(animations == 2, "activation leaves the existing flight alone")
        tabs.pageTransition.cancel()
    }

    @Test func repeatingAnAppRequestDoesNotFadeOrResetItsSegment() {
        let (tabs, window) = tabs(heights: [.apps: 300])
        tabs.open(.tab(.apps))
        defer { window.close() }
        let context = SettingsContext()
        context.tabs = tabs
        tabs.pageTransition.isVisible = { _ in true }
        var animations = 0
        tabs.pageTransition.animateGroup = { _, changes, _ in
            animations += 1
            changes()
        }
        let config = ConfigTree()
        var list = AppList()
        context.show(ShowRequest(app: "com.apple.Safari"))
        context.openRequested(in: &list, config: config)
        #expect(animations == 2)
        tabs.pageTransition.cancel()
        list.select(.scrolling)
        context.show(ShowRequest(app: "com.apple.Safari"))
        context.openRequested(in: &list, config: config)
        #expect(animations == 2)
        #expect(list.segment == .scrolling)
        #expect(context.app == nil)
        context.show(ShowRequest(app: "com.apple.TextEdit"))
        context.openRequested(in: &list, config: config)
        #expect(animations == 4)
        #expect(list.segment == .buttons)
        tabs.pageTransition.cancel()
    }

    @Test func aTallPaneLandsAtTheCap() {
        let (tabs, window) = tabs(heights: [.apps: 2400])
        tabs.open(.tab(.apps))
        #expect(window.contentLayoutRect.height <= SettingsWindowController.maxContentHeight)
        #expect(window.contentLayoutRect.height == LazyPane.maxHeight(on: window.screen))
    }
}
