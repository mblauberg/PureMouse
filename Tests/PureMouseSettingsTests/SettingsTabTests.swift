import AppKit
import PureMouseAppSupport
import SwiftUI
import Testing
@testable import PureMouseSettingsUI

// Settings' tabs and the Mouse tab's segments: what a request or the stored values open, and that
// a segment's pane is built only when it first shows.

@Suite struct SettingsTabTests {
    @Test func theToolbarShowsGeneralMouseAppsAbout() {
        #expect(SettingsTab.shown == [.general, .mouse, .apps, .about])
        #expect(SettingsTab.shown.map(\.title) == ["General", "Mouse", "Apps", "About"])
        #expect(MouseSegment.allCases.map(\.title) == ["Buttons", "Scrolling", "Pointer"])
    }

    @Test func aRequestForButtonsScrollingOrPointerOpensMouseOnThatSegment() {
        let current = SettingsSelection(tab: .general, segment: .buttons)
        for segment in MouseSegment.allCases {
            let pane = SettingsPane(rawValue: segment.rawValue)
            #expect(pane == .mouse(segment))
            #expect(pane.map(current.opening) == SettingsSelection(tab: .mouse, segment: segment))
        }
    }

    @Test func aRequestForATabKeepsTheMouseSegment() {
        let current = SettingsSelection(tab: .apps, segment: .pointer)
        #expect(SettingsPane(rawValue: "general").map(current.opening) == SettingsSelection(tab: .general, segment: .pointer))
        #expect(SettingsPane(rawValue: "mouse").map(current.opening) == SettingsSelection(tab: .mouse, segment: .pointer))
        #expect(SettingsPane(rawValue: "sideways") == nil)
        #expect(SettingsPane(rawValue: "Mouse") == nil)
    }

    @Test func eachRequestSpellsItselfTheWayItIsRead() {
        let all = SettingsTab.allCases.map(SettingsPane.tab) + MouseSegment.allCases.map(SettingsPane.mouse)
        for pane in all { #expect(SettingsPane(rawValue: pane.rawValue) == pane) }
    }

    @Test func aFirstRunOpensMouseOnButtons() {
        #expect(SettingsSelection.remembered(tab: nil, segment: nil) == SettingsSelection(tab: .mouse, segment: .buttons))
    }

    @Test func anUnknownStoredTabOpensMouse() {
        // "buttons" and "pointer" were tabs of their own before Mouse held them.
        for stored in ["buttons", "pointer", "Scrolling", "keyboard", ""] {
            #expect(SettingsSelection.remembered(tab: stored, segment: "scrolling") == SettingsSelection(tab: .mouse, segment: .scrolling))
        }
        #expect(SettingsSelection.remembered(tab: "apps", segment: "nonsense") == SettingsSelection(tab: .apps, segment: .buttons))
        #expect(SettingsSelection.remembered(tab: "general", segment: "pointer") == SettingsSelection(tab: .general, segment: .pointer))
    }
}

/// Counts the panes the Mouse tab asks for.
@MainActor
private final class PaneFactory {
    var built: [MouseSegment] = []
    let heights: [MouseSegment: CGFloat] = [.buttons: 300, .scrolling: 420, .pointer: 200]

    func make(_ segment: MouseSegment) -> NSViewController {
        built.append(segment)
        let pane = NSViewController()
        pane.view = NSView()
        pane.preferredContentSize = NSSize(width: 600, height: heights[segment]!)
        return pane
    }
}

@MainActor @Suite struct MouseTabTests {
    private func header(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return view
    }

    @Test func onlyTheShownSegmentIsBuiltAndEachIsBuiltOnce() {
        let factory = PaneFactory()
        let tab = MouseTab(segment: .scrolling, header: { _ in header(height: 40) }, make: factory.make)
        #expect(factory.built.isEmpty, "nothing is built before the tab shows")
        _ = tab.view
        #expect(factory.built == [.scrolling])
        tab.select(.pointer)
        #expect(factory.built == [.scrolling, .pointer])
        tab.select(.scrolling)
        tab.select(.pointer)
        #expect(factory.built == [.scrolling, .pointer], "a pane is kept once built")
        #expect(tab.builtSegments == [.scrolling, .pointer])
    }

    @Test func aSegmentChosenBeforeTheTabShowsIsTheOneBuilt() {
        let factory = PaneFactory()
        let tab = MouseTab(segment: .buttons, header: { _ in header(height: 40) }, make: factory.make)
        tab.select(.pointer)
        #expect(factory.built.isEmpty)
        _ = tab.view
        #expect(factory.built == [.pointer])
        #expect(tab.selection.segment == .pointer)
    }

    @Test func theTabIsTheStripPlusTheShownPaneTall() {
        let factory = PaneFactory()
        let tab = MouseTab(segment: .buttons, header: { _ in header(height: 40) }, make: factory.make)
        _ = tab.view
        #expect(tab.preferredContentSize.height == 340)
        tab.select(.scrolling)
        #expect(tab.preferredContentSize.height == 460)
        tab.select(.pointer)
        #expect(tab.preferredContentSize.height == 240)
    }

    @Test func choosingASegmentInTheStripTellsTheWindow() {
        let factory = PaneFactory()
        let tab = MouseTab(segment: .buttons, header: { _ in header(height: 40) }, make: factory.make)
        var told: [MouseSegment] = []
        tab.didSelect = { told.append($0) }
        _ = tab.view
        tab.selection.select(.scrolling)
        tab.selection.select(.scrolling)
        #expect(told == [.scrolling])
        #expect(tab.selection.segment == .scrolling)
    }
}

@MainActor @Suite struct SettingsTabsSelectionTests {
    @Test func noSelectionIsNotATab() {
        let tabs = SettingsTabs()
        #expect(tabs.selectedTabViewItemIndex == -1)
        #expect(tabs.selectedTab == nil)
        tabs.refit()
    }
}

// Find by Pressing belongs to Mouse › Buttons: any way of leaving it ends one under way.
@MainActor @Suite struct CaptureEndsWhenLeavingButtonsTests {
    private func mouseTab(_ segment: MouseSegment) -> MouseTab {
        MouseTab(segment: segment, header: { _ in NSView() }, make: { _ in
            let pane = NSViewController()
            pane.view = NSView()
            return pane
        })
    }

    @Test func aRequestForAnotherSegmentEndsItButStayingOnButtonsDoesNot() {
        let tab = mouseTab(.buttons)
        var ended = 0
        tab.willLeaveButtons = { ended += 1 }
        _ = tab.view
        tab.select(.buttons)
        #expect(ended == 0)
        tab.select(.pointer)
        #expect(ended == 1)
        tab.select(.scrolling)
        #expect(ended == 1, "only leaving Buttons counts")
    }

    @Test func theStripAndARequestShareThePath() {
        let tab = mouseTab(.buttons)
        var ended = 0
        tab.willLeaveButtons = { ended += 1 }
        _ = tab.view
        tab.selection.select(.scrolling)
        #expect(ended == 1)
    }

    private func tabs() -> SettingsTabs {
        let tabs = SettingsTabs()
        _ = tabs.view  // the tab view reports its selections to the controller once loaded
        for tab in SettingsTab.shown {
            let item = NSTabViewItem(viewController: NSViewController())
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    @Test func leavingTheMouseTabEndsItAndOtherChangesDoNot() {
        let tabs = tabs()
        var ended = 0
        tabs.didLeaveMouse = { ended += 1 }
        tabs.selectedTabViewItemIndex = SettingsTab.shown.firstIndex(of: .general)!
        tabs.selectedTabViewItemIndex = SettingsTab.shown.firstIndex(of: .apps)!
        #expect(ended == 0)
        tabs.selectedTabViewItemIndex = SettingsTab.shown.firstIndex(of: .mouse)!
        tabs.selectedTabViewItemIndex = SettingsTab.shown.firstIndex(of: .mouse)!
        #expect(ended == 0)
        tabs.open(.tab(.about))
        #expect(ended == 1)
    }
}

// MARK: Window sizing (docs/ui-design.md, "Sizing")

/// A form far taller than any window: 120 rows.
private struct TallPane: View {
    var body: some View {
        PaneForm {
            Section { ForEach(0..<120, id: \.self) { Text("Row \($0)") } }
        }
    }
}

private struct ShortPane: View {
    var body: some View {
        PaneForm { Section { Text("One row") } }
    }
}

@MainActor @Suite struct WindowSizingTests {
    private let cap = SettingsWindowController.maxContentHeight

    @Test func theCapIsSixHundredPoints() {
        #expect(cap == 600)
        #expect(LazyPane.maxHeight(on: nil) <= cap)
        #expect(LazyPane.fitted(NSSize(width: 600, height: 2400)).height <= cap)
    }

    @Test func aPaneTallerThanTheCapFitsAtTheCap() {
        let host = PaneHost(TallPane())
        let size = host.idealSize(maxHeight: cap)
        #expect(size.height == cap, "the form scrolls in the cap, not past it")
        #expect(host.measuredSize(maxHeight: cap).height <= cap)
    }

    @Test func aShorterPaneFitsItsContent() {
        let size = PaneHost(ShortPane()).idealSize(maxHeight: cap)
        #expect(size.height > 0)
        #expect(size.height < cap)
    }

    @Test func theLimitFollowsTheMaxHeightAsked() {
        let host = PaneHost(TallPane())
        #expect(host.idealSize(maxHeight: 540).height == 540)
        #expect(host.idealSize(maxHeight: 300).height == 300)
        #expect(host.idealSize(maxHeight: cap).height == cap)
    }

    @Test func fittingTheSameContentAgainGivesTheSameSize() {
        for pane in [AnyView(TallPane()), AnyView(ShortPane())] {
            let host = PaneHost(pane)
            let first = host.idealSize(maxHeight: cap)
            _ = host.view.fittingSize
            host.view.layoutSubtreeIfNeeded()
            let sizes = (0..<5).map { _ in host.idealSize(maxHeight: cap) }
            #expect(sizes.allSatisfy { $0 == first }, "\(sizes) vs \(first)")
        }
    }

    @Test func theMouseTabGivesTheFormWhatTheStripLeaves() {
        let strip: CGFloat = 60
        let tab = MouseTab(segment: .buttons, header: { _ in
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: strip).isActive = true
            view.widthAnchor.constraint(equalToConstant: 600).isActive = true
            return view
        }, make: { _ in PaneHost(TallPane()) })
        _ = tab.view
        let size = tab.idealSize(maxHeight: cap)
        #expect(size.height == cap, "strip plus form, no more")
        #expect(tab.preferredContentSize.height <= cap)
        #expect(tab.idealSize(maxHeight: cap) == size)
    }

    @Test func aLazyPaneOverATallPaneIsNoTallerThanTheCap() {
        let lazy = LazyPane { PaneHost(TallPane()) }
        _ = lazy.view
        #expect(lazy.preferredContentSize.height <= cap)
        #expect(lazy.idealSize(maxHeight: 4000).height <= cap)
        #expect(lazy.idealSize(maxHeight: 4000) == lazy.idealSize(maxHeight: 4000))
    }

    @Test func aPlainPanesPreferredSizeIsCappedToo() {
        let pane = NSViewController()
        pane.view = NSView()
        pane.preferredContentSize = NSSize(width: 600, height: 2400)
        #expect(pane.measuredSize(maxHeight: cap).height == cap)
    }

    @Test func aTabWithNothingToMeasureDoesNotFitTheWindow() {
        let tabs = SettingsTabs()
        _ = tabs.view
        let item = NSTabViewItem(viewController: NSViewController())
        item.identifier = SettingsTab.mouse.rawValue
        tabs.addTabViewItem(item)
        tabs.selectedTabViewItemIndex = 0
        tabs.refit()
        #expect(item.viewController?.preferredContentSize.height == 0)
    }

    private func controller() throws -> (SettingsWindowController, UserDefaults, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pm-sizing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appending(path: "config.json")
        try Data("{}".utf8).write(to: config)
        let locations = Locations(config: config, log: folder.appending(path: "log"), daemon: nil, companion: folder)
        let defaults = UserDefaults(suiteName: "pm-\(UUID().uuidString)")!
        let model = AppModel(locations: locations, defaults: defaults, alert: { _, _ in })
        return (SettingsWindowController(model: model, defaults: defaults), defaults, folder)
    }

    @Test func theAutosavedSizeIsNotApplied() throws {
        // What the old frame autosave left behind: a window 2400 pt tall.
        let key = "NSWindow Frame PureMouseSettings"
        let standard = UserDefaults.standard
        let before = standard.object(forKey: key)
        standard.set("100 100 600 2400 0 0 1920 1080", forKey: key)
        defer { before == nil ? standard.removeObject(forKey: key) : standard.set(before, forKey: key) }
        let (controller, _, folder) = try controller()
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = try #require(controller.window)
        #expect(window.frameAutosaveName.isEmpty, "nothing restores or saves the frame")
        #expect(window.frame.height < 1000)
        #expect(window.contentLayoutRect.height <= SettingsWindowController.maxContentHeight)
    }

    @Test func aRememberedPositionMovesTheWindowAndKeepsItsSize() throws {
        guard let screen = NSScreen.screens.first else { return }  // a Mac without a display
        let (controller, defaults, folder) = try controller()
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let size = window.frame.size
        let top = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.maxY - 90)
        defaults.set(NSStringFromPoint(top), forKey: "SettingsWindowTopLeft")
        #expect(controller.restorePosition(of: window))
        #expect(window.frame.size == size)
        #expect(window.frame.minX == top.x)
        #expect(window.frame.maxY == top.y)
    }

    @Test func aRememberedPositionOffEveryScreenIsIgnored() throws {
        let (controller, defaults, folder) = try controller()
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        defaults.set(NSStringFromPoint(NSPoint(x: -90000, y: 90000)), forKey: "SettingsWindowTopLeft")
        #expect(!controller.restorePosition(of: window))
    }
}
