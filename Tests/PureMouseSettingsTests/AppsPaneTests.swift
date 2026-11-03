import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The Apps tab and an app's page: the inherited-value presentation, and, read from the sources,
// the words docs/ui-language.md retires, how the page opens and closes, and that the editors are sheets.

@Test func anUnsetValueLooksAsItDoesEverywhereAndAnOwnOneSaysSo() {
    let unset = InheritedValue<String>(own: nil, inherited: "Mission Control", source: "Mouse Settings")
    #expect(unset.isInherited)
    #expect(unset.effective == "Mission Control")
    #expect(unset.caption == nil)
    #expect(unset.entry == "Same as Mouse Settings")
    #expect(unset.spoken == "Mission Control, same as Mouse Settings")

    let own = InheritedValue(own: "Mute", inherited: "Mission Control", source: "Mouse Settings")
    #expect(!own.isInherited)
    #expect(own.effective == "Mute")
    #expect(own.caption == "Set for this app.")
    #expect(own.resetTitle == "Use Mouse Setting")
    #expect(own.spoken == "Mute")

    // The source word is the caller's: a mouse inherits from all mice.
    #expect(InheritedValue(own: nil as Int?, inherited: 1600, source: "All Mice").caption == nil)
    #expect(InheritedValue(own: 1200, inherited: 1600, source: "All Mice").caption == "Set for this mouse.")
}

@MainActor @Test func anAppsButtonRowShowsTheActionEverywhereUntilItSetsOne() {
    let unset = ActionButton.inherited(.standard, everywhere: "Mission Control")
    #expect(unset.effective == "Mission Control" && unset.caption == nil)
    let set = ActionButton.inherited(.named("missionControl"), everywhere: "Default")
    #expect(set.effective == ButtonAction.named("missionControl").label && set.caption == "Set for this app.")
    // The picker keeps the entry that removes the app's own binding.
    let entry = PickerEntry.all(allowsDefault: false, allowsGesture: true, inherited: ActionButton.inherited(.standard, everywhere: "Mission Control")).first
    #expect(entry?.label == "Same as Mouse Settings" && entry?.detail == "(Mission Control)")
}

@Test func anAppsEditorSubtitleNamesTheApp() {
    let target = BindingTarget(button: "top", app: "com.apple.Safari", appName: "Safari")
    #expect(target.subtitle == "For the top button in Safari.")
    let turning = BindingTarget(button: "thumbWheel", direction: "left", app: "com.apple.Safari",
                                label: "turning the thumb wheel left", appName: "Safari")
    #expect(turning.subtitle == "For turning the thumb wheel left in Safari.")
    #expect(BindingTarget(button: "top").subtitle == "For the top button.")
}

@Test func miceThatDifferShowVariesByMouseAsTheInheritedValue() {
    // The pop-up's first entry and the closed value both say it, and VoiceOver reads it with its source.
    let unset = InheritedValue<String>(own: nil, inherited: "Varies by Mouse", source: InheritedScope.mouseSettings)
    #expect(unset.effective == "Varies by Mouse")
    #expect("\(unset.entry) (\(unset.inherited))" == "Same as Mouse Settings (Varies by Mouse)")
    #expect(unset.spoken == "Varies by Mouse, same as Mouse Settings")
    let wheel = ActionButton.inherited(.standard, everywhere: "Varies by Mouse")
    #expect(wheel.effective == "Varies by Mouse" && wheel.caption == nil)
    let entry = PickerEntry.all(allowsDefault: true, allowsGesture: true, inherited: wheel).first
    #expect(entry?.label == "Same as Mouse Settings" && entry?.detail == "(Varies by Mouse)")
    // Resetting an app's own value is "Use Mouse Setting", not "Use Mouse Settings Setting".
    #expect(InheritedScope.use(InheritedScope.mouseSettings) == "Use Mouse Setting")
    #expect(InheritedScope.use(InheritedScope.allMice) == "Use All Mice Setting")
}

@Suite struct AppsPaneSources {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: sources.appending(path: path), encoding: .utf8)
    }

    private static let files = ["PureMouseSettingsUI/AppsPane.swift", "PureMouseSettingsUI/AppPage.swift",
                                "PureMouseSettingsUI/ThumbWheelRows.swift", "PureMouseAppSupport/AppSettings.swift"]

    @Test func noRetiredWordsInTheAppsTab() throws {
        for file in Self.files {
            let text = try Self.source(file)
            for retired in ["so not saved", "No settings yet", "Own scrolling speed", "frontmost app", "\"Everywhere: ",
                            "No apps yet", "has no bundle identifier", "·", "AppSheet", "Same as Everywhere"] {
                #expect(!text.contains(retired), "\(file) says \(retired)")
            }
        }
    }

    // Criterion 1: ‹ Apps, ⌘[ and Esc return to the list.
    @Test func backIsAButtonWithCommandBracketAndEscapeReturns() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        #expect(page.contains(#"Label("Apps", systemImage: "chevron.left")"#))
        #expect(page.contains(#".keyboardShortcut("[", modifiers: .command)"#))
        #expect(page.contains(".keyboardShortcut(.cancelAction)"))
        #expect(page.contains(#".accessibilityLabel("Back to Apps")"#))
        // The Apps tab shows the page in place of the list, and the row and the request open the same one.
        let apps = try Self.source("PureMouseSettingsUI/AppsPane.swift")
        #expect(apps.contains("AppPage(key:") && apps.contains("back: { list.close() }"))
        #expect(apps.contains("list.show(id)") && apps.contains("list.add(id, in: model.config)"))
        #expect(!apps.contains(".sheet("))
    }

    // Criterion 2: Buttons and Scrolling, no Pointer; Thumb Wheel under Scrolling.
    @Test func thePageHasTwoSegmentsAndNoPointer() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        #expect(page.contains("AppSegment.allCases") && !page.contains("MouseSegment"))
        let scrolling = try #require(page.range(of: "private func scrolling("))
        let thumb = try #require(page.range(of: "ThumbWheelRows("))
        #expect(thumb.lowerBound > scrolling.lowerBound)
    }

    // Criterion 8: the editors are sheets, wherever they open from.
    @Test func theEditorsAreSheetsAndNothingIsAPopover() throws {
        let editors = try Self.source("PureMouseSettingsUI/EditorPresentation.swift")
        #expect(editors.contains("sheet(item:") && !editors.contains("popover") && !editors.contains("EditorPresentation"))
        for file in ["AppPage", "ThumbWheelRows"] {
            let text = try Self.source("PureMouseSettingsUI/\(file).swift")
            #expect(text.contains(".actionEditorSheet(") && !text.contains("actionEditorPopover") && !text.contains("editorPresentation"))
        }
    }
}
