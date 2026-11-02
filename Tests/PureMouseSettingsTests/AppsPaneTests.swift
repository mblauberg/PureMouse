import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The Apps tab and its app sheet: the inherited-value presentation, and, read from the sources,
// the words docs/ui-language.md retires and that no sheet opens from the app sheet.

@Test func anUnsetValueShowsWhatAppliesDimmedWithItsSource() {
    let unset = InheritedValue<String>(own: nil, inherited: "Mission Control", source: "Everywhere")
    #expect(unset.isInherited)
    #expect(unset.effective == "Mission Control")
    #expect(unset.caption == "Same as Everywhere")
    #expect(unset.entry == "Same as Everywhere")
    #expect(unset.spoken == "Mission Control, same as Everywhere")

    let own = InheritedValue(own: "Mute", inherited: "Mission Control", source: "Everywhere")
    #expect(!own.isInherited)
    #expect(own.effective == "Mute")
    #expect(own.caption == nil)
    #expect(own.spoken == "Mute")

    // The source word is the caller's: a mouse inherits from all mice.
    #expect(InheritedValue(own: nil as Int?, inherited: 1600, source: "All Mice").caption == "Same as All Mice")
}

@MainActor @Test func anAppsButtonRowShowsTheActionEverywhereUntilItSetsOne() {
    let unset = ActionButton.inherited(.standard, everywhere: "Mission Control")
    #expect(unset.effective == "Mission Control" && unset.caption == "Same as Everywhere")
    let set = ActionButton.inherited(.named("missionControl"), everywhere: "Default")
    #expect(set.effective == ButtonAction.named("missionControl").label && set.caption == nil)
    // The picker keeps the entry that removes the app's own binding.
    let entry = PickerEntry.all(allowsDefault: false, allowsGesture: true, sameAsEverywhere: "Mission Control").first
    #expect(entry?.label == "Same as Everywhere" && entry?.detail == "(Mission Control)")
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
