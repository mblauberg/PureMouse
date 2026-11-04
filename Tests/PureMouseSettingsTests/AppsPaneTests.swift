import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The Apps tab and an app's page: the inherited-value presentation, and, read from the sources,
// the words docs/ui-language.md retires, how the page opens and closes, and that the editors are sheets.

@Test func anUnsetValueLooksAsTheWiderScopeHasItAndAnOwnOneSaysSo() {
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

@MainActor @Test func anAppsButtonRowShowsTheInheritedActionUntilItSetsOne() {
    let unset = ActionButton.inherited(.standard, inheriting: "Mission Control")
    #expect(unset.effective == "Mission Control" && unset.caption == nil)
    let set = ActionButton.inherited(.named("missionControl"), inheriting: "Default")
    #expect(set.effective == ButtonAction.named("missionControl").label && set.caption == "Set for this app.")
    // The picker keeps the entry that removes the app's own binding.
    let entry = PickerEntry.all(allowsDefault: false, allowsGesture: true, inherited: ActionButton.inherited(.standard, inheriting: "Mission Control")).first
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
    let wheel = ActionButton.inherited(.standard, inheriting: "Varies by Mouse")
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
        #expect(apps.contains("AppPage(key:") && apps.contains("back: { navigate { list.close() } }"))
        #expect(apps.contains("list.show(id)") && apps.contains("list.add(id, in: model.config)"))
        #expect(!apps.contains(".sheet("))
    }

    // Choosing another app starts a page: no editor, picker, disclosure or icon is left from the last.
    // (A view's identity is not observable from a test, so the source is checked.)
    @Test func eachAppsPageHasItsOwnIdentity() throws {
        let apps = try Self.source("PureMouseSettingsUI/AppsPane.swift")
        let call = try #require(apps.range(of: "AppPage(key:"))
        #expect(apps[call.lowerBound...].prefix(400).contains(".id(key)"))
    }

    // The hidden Esc button is not a stop for Tab, and the page reads as the Mouse tab's rows do.
    @Test func theEscapeButtonIsNotFocusableAndTheRowsFollowTheMouseTabs() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        let esc = try #require(page.range(of: ".keyboardShortcut(.cancelAction)"))
        #expect(page[esc.upperBound...].prefix(200).contains(".focusable(false)"))
        // One order of named rows for both pages, and each mouse's own bound buttons are listed.
        #expect(page.contains("ButtonRows.named(deviceCIDs:"))
        #expect(page.contains("mice.map { config.prefix(of: $0) }"))
        #expect(page.contains(".actionEditorSheet($editor) { action, target in apply(action, to: target) }"))
        #expect(page.contains("inheriting: mice)"))
        #expect(ButtonRows.named(deviceCIDs: nil, configKeys: []).prefix(2).map(\.rawValue) == ["back", "forward"])
    }

    // The sliders and the thumb wheel's directions say "Varies by Mouse" while the mice differ.
    @Test func theSlidersAndDirectionsSayWhenTheMiceDiffer() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        #expect(page.contains("variesText: speedVaries") && page.contains("variesText: glideVaries"))
        #expect(page.contains("inheritedVariesKeys: config.thumbWheelKeysVarying(inheriting: mice, ownPath: scope + [\"thumbWheel\"])"))
        #expect(page.contains("config.thumbWheelVaries(inheriting: mice)"))
        // Turn distance and Swap directions say it too, while the app leaves them to the mice.
        let rows = try Self.source("PureMouseSettingsUI/ThumbWheelRows.swift")
        #expect(rows.contains(#"inheritedVariesKeys.contains("step")"#) && rows.contains(#"inheritedVariesKeys.contains("reversed")"#))
    }

    // The header is a view of its own above the form, as the Mouse tab's strip is above its pane, so
    // no scroll-edge line is drawn under it and the form starts where the Mouse page's does.
    @Test func theHeaderIsItsOwnViewAboveTheForm() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        #expect(!page.contains("safeAreaInset"))
        let body = try #require(page.range(of: "var body: some View {"))
        let rest = page[body.upperBound...]
        let header = try #require(rest.range(of: "AppPageHeader("))
        let form = try #require(rest.range(of: "PaneForm {"))
        #expect(header.lowerBound < form.lowerBound)
        // The form's cap leaves room for the header, from the pane's limit, not the screen's.
        #expect(page.contains("paneMaxHeight") && !page.contains("LazyPane.fitted"))
    }

    // Off dims what both segments show, below the switch; the segments stay live, so a person can
    // still look at either segment's settings while PureMouse is off in the app.
    @Test func offDimsBothSegmentsRowsButNotTheSegmentsThemselves() throws {
        let page = try Self.source("PureMouseSettingsUI/AppPage.swift")
        #expect(page.contains("case .scrolling: scrolling(model.config)"))
        #expect(page.contains(".disabled(!model.config.isAppEnabled(key))"))
        #expect(!page.contains("var enabled = true"))
    }

    // A `Menu` takes its label apart into a title and an image and draws the image first, so a pop-up
    // whose label is a stack (value, then chevrons) read chevrons-first on every pop-up that is a
    // `Menu`. `PopUpLabel` is one `Text` with the chevrons set in it, and every pop-up uses it.
    @Test func everyPopUpDrawsItsValueBeforeTheChevronsThroughOneLabel() throws {
        let components = try Self.source("PureMouseSettingsUI/Components.swift")
        let label = try #require(components.range(of: "struct PopUpLabel: View {"))
        let end = try #require(components.range(of: "struct PopUpMenu", range: label.upperBound..<components.endIndex))
        let body = components[label.upperBound..<end.lowerBound]
        #expect(body.contains(#"Text(Image(systemName: "chevron.up.chevron.down"))"#))
        #expect(!body.contains("HStack") && !body.contains("VStack"))
        #expect(components.contains("PopUpLabel(text: text)"))
        #expect(try Self.source("PureMouseSettingsUI/ActionPicker.swift").contains("PopUpLabel(text:"))
        // The thumb wheel's Action row is a pop-up of this kind, with or without a wider scope.
        let rows = try Self.source("PureMouseSettingsUI/ThumbWheelRows.swift")
        #expect(rows.contains("InheritedPicker(") && rows.contains("PopUpMenu(text: choice.label)"))
        #expect(try Self.source("PureMouseSettingsUI/InheritedValue.swift").contains("PopUpMenu(text:"))
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

#if DEBUG
@MainActor @Test func theDevAppHookNeedsANonEmptyBundleID() {
    #expect(AppsPane.devApp(["PUREMOUSE_DEV_APP": "com.apple.Safari"]) == "com.apple.Safari")
    #expect(AppsPane.devApp(["PUREMOUSE_DEV_APP": ""]) == nil, "an empty value shows the list, not a blank page")
    #expect(AppsPane.devApp([:]) == nil)
}
#endif
