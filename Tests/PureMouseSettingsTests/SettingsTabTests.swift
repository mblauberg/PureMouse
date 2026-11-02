import AppKit
import PureMouseAppSupport
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
