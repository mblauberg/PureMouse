import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The Apps tab and its app sheet: the inherited-value presentation, and, read from the sources,
// the words docs/ui-language.md retires and that no sheet opens from the app sheet.

@Test func anUnsetValueLooksAsItDoesEverywhereAndAnOwnOneSaysSo() {
    let unset = InheritedValue<String>(own: nil, inherited: "Mission Control", source: "Everywhere")
    #expect(unset.isInherited)
    #expect(unset.effective == "Mission Control")
    #expect(unset.caption == nil)
    #expect(unset.entry == "Same as Everywhere")
    #expect(unset.spoken == "Mission Control, same as Everywhere")

    let own = InheritedValue(own: "Mute", inherited: "Mission Control", source: "Everywhere")
    #expect(!own.isInherited)
    #expect(own.effective == "Mute")
    #expect(own.caption == "Set for this app.")
    #expect(own.resetTitle == "Use Everywhere Setting")
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
    #expect(entry?.label == "Same as Everywhere" && entry?.detail == "(Mission Control)")
}

@Test func anAppsEditorSubtitleNamesTheApp() {
    let target = BindingTarget(button: "top", app: "com.apple.Safari", appName: "Safari")
    #expect(target.subtitle == "For the top button in Safari.")
    let turning = BindingTarget(button: "thumbWheel", direction: "left", app: "com.apple.Safari",
                                label: "turning the thumb wheel left", appName: "Safari")
    #expect(turning.subtitle == "For turning the thumb wheel left in Safari.")
    #expect(BindingTarget(button: "top").subtitle == "For the top button.")
}

@Suite struct AppsPaneSources {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: sources.appending(path: path), encoding: .utf8)
    }

    private static let files = ["PureMouseSettingsUI/AppsPane.swift", "PureMouseSettingsUI/AppSheet.swift",
                                "PureMouseSettingsUI/ThumbWheelRows.swift", "PureMouseAppSupport/AppSettings.swift"]

    @Test func noRetiredWordsInTheAppsTab() throws {
        for file in Self.files {
            let text = try Self.source(file)
            for retired in ["so not saved", "No settings yet", "Own scrolling speed", "frontmost app", "\"Everywhere: ",
                            "No apps yet", "has no bundle identifier", "·"] {
                #expect(!text.contains(retired), "\(file) says \(retired)")
            }
        }
    }

    @Test func noSheetOpensFromTheAppSheet() throws {
        let sheet = try Self.source("PureMouseSettingsUI/AppSheet.swift")
        #expect(!sheet.contains(".sheet("))
        #expect(sheet.contains(".environment(\\.editorPresentation, .popover)"))
        // The thumb wheel's editors follow the same environment value as the button rows.
        let wheel = try Self.source("PureMouseSettingsUI/ThumbWheelRows.swift")
        #expect(!wheel.contains(".sheet("))
        #expect(wheel.contains(".actionEditorPopover("))
    }
}
