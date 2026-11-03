import Foundation
import PureMouseAppSupport
import PureMouseKit
import SwiftUI
import Testing
@testable import PureMouseSettingsUI

// Mouse › Buttons and Scrolling, and the sheets they open: the picker's haptic group, the sheets'
// words, and the words docs/ui-language.md retires, read from the sources.

// MARK: Action picker

@Test func thePickerNamesEntriesWithoutAsides() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    #expect(byID["default"]?.label == "Mouse Default" && byID["default"]?.detail == nil)
    #expect(byID["gesture"]?.label == "Hold and Move" && byID["gesture"]?.detail == nil)
    #expect(byID["run"]?.label == "Run Command…")
}

@Test func hapticEntriesFollowTheMouse() {
    let haptic = { (entries: [PickerEntry]) in entries.filter(\.isHaptic).count }
    #expect(haptic(PickerEntry.all(allowsDefault: true, allowsGesture: true)) == HapticWaveform.allCases.count)
    #expect(haptic(PickerEntry.all(allowsDefault: true, allowsGesture: true, haptics: false)) == 0)
}

@Test func hapticEntriesSitInACollapsedGroup() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
    // Collapsed: one row for the group, none for its entries, in the group's place before Custom.
    let collapsed = PickerItem.visible(entries, query: "", hapticsOpen: false)
    #expect(collapsed.filter { $0 == .hapticGroup(expanded: false) }.count == 1)
    #expect(!collapsed.contains { if case .entry(let entry) = $0 { entry.isHaptic } else { false } })
    let group = collapsed.firstIndex(of: .hapticGroup(expanded: false))!
    #expect(collapsed.firstIndex { $0.id == "keys" }! == group + 1)
    // Opened by hand, or for a current haptic action.
    let open = PickerItem.visible(entries, query: "", hapticsOpen: true)
    #expect(open.count == collapsed.count + HapticWaveform.allCases.count)
    #expect(open.contains(.hapticGroup(expanded: true)))
    #expect(PickerItem.opensHaptics(for: .haptic("happyAlert")))
    #expect(!PickerItem.opensHaptics(for: .named("missionControl")))
    // A search that matches a waveform opens it; one that matches none leaves the group out.
    let search = PickerItem.visible(entries, query: "happy", hapticsOpen: false)
    #expect(search.map(\.id) == [PickerItem.hapticGroupID, "haptic.happyAlert"])
    #expect(!PickerItem.visible(entries, query: "zoom", hapticsOpen: false).contains { $0.id == PickerItem.hapticGroupID })
    // Without haptics there is no group.
    let none = PickerItem.visible(PickerEntry.all(allowsDefault: true, allowsGesture: true, haptics: false),
                                  query: "", hapticsOpen: true)
    #expect(!none.contains { $0.id == PickerItem.hapticGroupID })
    // The group's entries sit under its row, not a header of their own.
    #expect(open.allSatisfy { $0.section != ActionCatalog.hapticGroup })
}

@MainActor @Test func aLongBindingIsShortenedInTheMiddle() {
    #expect(ActionButton.shortened("⌘W") == "⌘W")
    let long = ActionButton.shortened("open -a Safari https://example.com/some/long/path")
    #expect(long.count == ActionButton.labelLimit && long.contains("…") && long.hasPrefix("open -a"))
}

// MARK: Sheets

@Test func sheetsNameTheControlAndTheApp() {
    #expect(BindingTarget(button: "top", app: "com.apple.Safari", appName: "Safari").subtitle == "For the top button in Safari.")
    #expect(BindingTarget(button: "gesture", direction: "up").subtitle == "For the gesture button, move up.")
    #expect(BindingTarget(button: "gesture", direction: "left", app: "x", appName: "Mail").subtitle
        == "For the gesture button in Mail, move left.")
    #expect(BindingTarget(button: "thumbWheel", direction: "left", label: "turning the thumb wheel left").subtitle
        == "For turning the thumb wheel left.")
    #expect(BindingTarget(button: "0x00d7").subtitle == "For control 0x00d7.")
}

@MainActor @Test func theShortcutAndCommandSheetsSayWhatTheyDo() {
    #expect(RecorderField.idle == "Record Shortcut")
    #expect(RecorderField.recording == "Recording…")
    #expect(ShortcutSheet.typingPrompt == "Or enter it, such as ctrl+left")
    #expect(ShortcutSheet.caption == "macOS keeps some shortcuts, such as ⌃←. Enter those instead.")
    #expect(ShortcutSheet.syntaxError.hasSuffix("."))
    #expect(CommandSheet.title == "Run Command")
    #expect(CommandSheet.caption == "Runs as your user account. Output isn't shown.")
}

// MARK: Sources

@Suite struct MousePaneSourceTests {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: ui.appending(path: name), encoding: .utf8)
    }

    /// The string literals in a source.
    private static func literals(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0].dropFirst().dropLast()) }
        }
    }

    /// Every Settings source.
    private static var files: [URL] {
        let enumerator = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func noRetiredWordsInUIStrings() throws {
        let retired = ["Mouse default.", "Works as Normal", "(Gestures)", "Turn per action", "Threshold", "Fine-tune",
                       "Select by Pressing", "Run Shell Command", "Click to record", "Classic wheel direction"]
        let controls = NamedButton.allCases.map(\.label) + ["the ", "Control "]
        #expect(Self.files.count > 10)
        for file in Self.files {
            for literal in Self.literals(try String(contentsOf: file, encoding: .utf8)) {
                for word in retired {
                    // A whole word: "Threshold" is retired, the key "smartShiftThreshold" is not.
                    let bounded = word.first!.isLetter ? #"\b"# + NSRegularExpression.escapedPattern(for: word) : nil
                    let found = bounded.map { literal.range(of: $0, options: .regularExpression) != nil } ?? literal.contains(word)
                    #expect(!found, "\(file.lastPathComponent) says \(literal)")
                }
                #expect(!controls.contains { literal.hasPrefix("What " + $0) || literal.hasPrefix("What \\(") },
                        "\(file.lastPathComponent) says \(literal)")
                #expect(!literal.contains("×"), "\(file.lastPathComponent) says \(literal)")
            }
        }
    }

    @Test func accelerationReadsAsAStrength() throws {
        let scrolling = try Self.source("ScrollingPane.swift")
        let row = try #require(scrolling.range(of: #"ValueSlider(title: "Acceleration""#).map { String(scrolling[$0.lowerBound...].prefix(400)) })
        #expect(row.contains("format: Format.strength"))
    }

    @Test func thePickerDrawsTheSystemSelection() throws {
        let picker = try Self.source("ActionPicker.swift")
        for drawn in [#"accentColor"#, #"\.white\b"#, #"\.stroke\("#] {
            #expect(picker.range(of: drawn, options: .regularExpression) == nil, "ActionPicker uses \(drawn)")
        }
        #expect(picker.contains("List(selection:"))
        #expect(!picker.contains(".frame(width: 168)"))
    }

    @MainActor @Test func restoreDefaultsAsksFirstOnBothSegments() throws {
        #expect(ButtonsPane.restoreMessage == "Buttons and gestures return to PureMouse's defaults. App settings don't change.")
        #expect(ScrollingPane.restoreMessage
            == "Scrolling and thumb wheel settings return to PureMouse's defaults. App settings don't change.")
        for (file, restore) in [("ButtonsPane.swift", "restoreButtonDefaults(in:"), ("ScrollingPane.swift", "restoreScrollingDefaults(in:")] {
            let text = try Self.source(file)
            // The only call is PaneFooter's, which runs it from its confirmation's button.
            let lines = text.components(separatedBy: "\n").filter { $0.contains(restore) }
            #expect(lines.count == 1 && lines[0].contains("PaneFooter(restoreDefaults:"), "\(file)")
            #expect(text.contains("?? Self.restoreMessage"), "\(file)")
        }
        let footer = try Self.source("Components.swift")
        #expect(footer.contains(#"Button("Restore Defaults", action: restoreDefaults)"#))
    }
}

// MARK: A mouse's inherited values (#54)

@MainActor @Test func aMouseAndAnAppShowAnInheritedValueThroughTheSameType() {
    // One type, one rule: an inherited value has no caption and no mark; an own one says "Set for <owner>."
    let app = InheritedValue<String>(own: nil, inherited: "Mute", source: InheritedScope.everywhere)
    let mouse = InheritedValue<String>(own: nil, inherited: "Mute", source: InheritedScope.allMice)
    #expect(type(of: app) == type(of: mouse))
    #expect(app.effective == mouse.effective && app.caption == nil && mouse.caption == nil)
    let notes = [app.note {}, mouse.note {}]
    #expect(notes.allSatisfy { $0 == nil })
    let ownApp = InheritedValue<String>(own: "Volume Up", inherited: "Mute", source: InheritedScope.everywhere)
    let ownMouse = InheritedValue<String>(own: "Volume Up", inherited: "Mute", source: InheritedScope.allMice)
    #expect(ownApp.effective == "Volume Up" && ownMouse.effective == "Volume Up")
    #expect(ownApp.caption == "Set for this app." && ownMouse.caption == "Set for this mouse.")
    #expect(ownApp.resetTitle == "Use Everywhere Setting" && ownMouse.resetTitle == "Use All Mice Setting")
    // The Buttons list builds both from the same function.
    let button = ActionButton.inherited(.standard, everywhere: "Mission Control", source: InheritedScope.allMice)
    #expect(button.caption == nil && button.effective == "Mission Control")
    #expect(ActionButton.inherited(.named("mute"), everywhere: "Mission Control", source: InheritedScope.allMice).caption
        == "Set for this mouse.")
}

@MainActor @Test func anOverriddenRowOffersToUseTheAllMiceSettingAndAnInheritingOneSaysNothing() {
    var given = 0
    let own = InheritedValue(own: true, inherited: false, source: InheritedScope.allMice)
    let note = own.note { given += 1 }
    let words = [note?.caption, note?.resetTitle]
    #expect(words == ["Set for this mouse.", "Use All Mice Setting"])
    note?.reset()
    #expect(given == 1)
    let inheriting = InheritedValue<Bool>(own: nil, inherited: false, source: InheritedScope.allMice).note { given += 1 }
    #expect(inheriting == nil)
    #expect(given == 1)
}

@MainActor @Test func aChangedRowMovesItsHelpToATooltipAndAnInheritingRowKeepsItAsItsCaption() {
    let note = InheritedValue(own: 1, inherited: 2, source: InheritedScope.allMice).note {}
    // Inheriting, the row reads as it does in the wider scope.
    #expect(RowLabel("Speed", help: "Higher moves the pointer further.").captionText == "Higher moves the pointer further.")
    // Changed, the help is the tooltip and the caption line is "Set for this mouse." with its button.
    let changed = RowLabel("Speed", help: "Higher moves the pointer further.", note: note).captionText
    let unsupported = RowLabel("Speed", help: "Higher moves the pointer further.", availability: .unsupportedButConfigured, note: note).captionText
    #expect(changed == nil)
    #expect(unsupported == ControlAvailability.unsupportedCaption)
    #expect(InheritedOverride.tooltip(for: "Higher moves the pointer further.") == "Higher moves the pointer further.")
}

@Test func everyTooltipIsUnder75Characters() {
    let long = "Higher moves the pointer further for the same hand movement. Available speeds depend on your mouse."
    #expect(InheritedOverride.tooltip(for: long) == "Higher moves the pointer further for the same hand movement.")
    let unbroken = String(repeating: "word ", count: 30)
    #expect(InheritedOverride.tooltip(for: unbroken).count <= ActionButton.tooltipLimit)
    #expect(InheritedOverride.tooltip(for: nil) == "" && InheritedOverride.tooltip(for: " ") == "")
}

@Suite struct InheritedPresentationSources {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: ui.appending(path: name), encoding: .utf8)
    }

    private static let files = ["PointerPane", "ScrollingPane", "ButtonsPane", "ThumbWheelRows", "AppSheet", "Components", "PresetsSheet"]

    @Test func nothingDimsAnInheritedValueOrHidesATrailingSlot() throws {
        let everything = try (Self.files + ["InheritedValue", "ActionPicker"]).map { try Self.source($0 + ".swift") }.joined(separator: "\n")
        // ActionPicker's own `.opacity` keeps a checkmark's room; no pane hides anything this way.
        for file in Self.files { #expect(!(try Self.source(file + ".swift")).contains(".opacity("), "\(file)") }
        for retired in ["InheritedReset", "InheritedChoiceRow", "InheritedRow", "HierarchicalShapeStyle"] {
            #expect(!everything.contains(retired), "\(retired)")
        }
        // The caption words are the glossary's: no "Same as" outside a pop-up's entry.
        let words = try Self.source("InheritedValue.swift")
        #expect(words.contains("\"Same as \\(source)\"") && words.contains("\"Set for \\(owner(of: source)).\""))
    }

    @Test func theChangeButtonIsALinkAndEveryChangedRowOffersItAsAMenuAndAnAction() throws {
        // The line's words and the row's extras are one place's; which rows use them is tested by row,
        // in "A mouse's rows" below.
        let words = try Self.source("InheritedValue.swift")
        #expect(words.contains(".accessibilityAddTraits(.isLink)"))
        #expect(words.contains(".contextMenu") && words.contains(".accessibilityActions"))
        // ValueSlider applies it itself.
        #expect(try Self.source("Components.swift").contains(".overridable(note, help: help)"))
    }

    @Test func aRowsControlIsTheSameInEveryScope() throws {
        // No branch on the scope picks another control: the pane reads and writes in the scope it shows.
        let scrolling = try Self.source("ScrollingPane.swift")
        #expect(!scrolling.contains("if isMouse {"))
        // The thumb wheel rows branch on the scope only to pick where an edit is written.
        let wheel = try Self.source("ThumbWheelRows.swift")
        #expect(wheel.components(separatedBy: "if isMouse {").count == 2 && wheel.contains("model.update(debounce: debounce, in: model.scopeTarget, change)"))
        #expect(!(try Self.source("ScrollingPane.swift")).contains("InheritedPicker"))
    }
}

@Test func theMousePopUpSaysAppsAreSharedAndNamesTheMouseItEdits() throws {
    #expect(MousePopUp.appsNote == "Apps are the same for every mouse.")
    // The one explanation of a mouse's rows, said once, beside the Apps note in the menu.
    #expect(MousePopUp.followNote == "Settings you don't change follow All Mice.")
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI/MouseTab.swift"), encoding: .utf8)
    #expect(source.components(separatedBy: "Text(Self.followNote)").count == 2)
    // It shows only when the model offers the choice, and carries the note in its tooltip and hint.
    #expect(source.contains("model.showsMouseMenu"))
    #expect(source.contains(".help(Self.appsNote)") && source.contains(#".accessibilityHint("\(Self.followNote) \(Self.appsNote)")"#))
}

// MARK: Writes land in the scope the pane edits (#54)

private let writeCall = #"(model\.(update|set|setDPI|toggle)(\(|\s*\{)|\$0\.(set|bind)\()"#

/// The write calls in the panes and sheet that edit a mouse, as `(file, line, text)`, that name no scope: a
/// `model.update`, `model.set`, `model.setDPI` or `model.toggle` without `in:`, and a `$0.set` or
/// `$0.bind` without `in:`. A line that is meant for All Mice alone says so with a `// All Mice` comment.
private func unscopedWrites() throws -> [String] {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")
    let call = try Regex(writeCall)
    var found: [String] = []
    for file in ["PointerPane", "ButtonsPane", "ScrollingPane", "ThumbWheelRows", "PresetsSheet"] {
        let lines = try String(contentsOf: sources.appending(path: "\(file).swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (number, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            guard line.contains(call) else { continue }
            // The call's own arguments: its line and the next, which a long one wraps onto.
            let statement = line + (number + 1 < lines.count ? lines[number + 1] : "")
            if !statement.contains("in:") && !line.contains("// All Mice") { found.append("\(file):\(number + 1) \(line.trimmingCharacters(in: .whitespaces))") }
        }
    }
    return found
}

@Test func everyWriteInTheMousePanesNamesTheScopeItEditsOrSaysItIsForAllMiceOnly() throws {
    let offenders = try unscopedWrites()
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test func theScopeScanSeesAWriteThatLostItsScope() {
    // Guards the scan itself: the three mutants it exists for would each be reported.
    let mutants = ["model.setDPI(dpi, debounce: debounce)", "model.update { $0.apply(feel) }", "model.update(debounce: debounce, change)"]
    let call = try! Regex(writeCall)
    for mutant in mutants { #expect(mutant.contains(call) && !mutant.contains("in:")) }
}

// MARK: A mouse's thumb wheel builds on All Mice's (#54)

private let wheelMouse = "mb03400000000"
private let swappedVolume = #"{"thumbWheel":{"action":"volume","reversed":true},"devices":{"mb03400000000":{"name":"MX","dpi":800}}}"#

@MainActor @Test func aMouseThatInheritsANonScrollActionShowsTheAdvancedRowsTheLayoutSays() throws {
    let config = try ConfigTree(data: Data(swappedVolume.utf8))
    let scope = try #require(ConfigScope.device(wheelMouse))
    let path = config.prefix(of: scope) + ["thumbWheel"]
    let layout = ScrollingLayout(config: config, devices: [], scope: scope)
    let rows = ThumbWheelRows.advancedRows(config, path: path, base: ThumbWheelRows.base(config, scope)).map(ScrollingLayout.Row.thumbWheel)
    #expect(rows == layout.advancedThumbWheelRows)
    #expect(!rows.isEmpty)
    // Built on nothing, the wheel would scroll and offer other rows: the mutant this guards.
    let onNothing = ThumbWheelRows.advancedRows(config, path: path, base: .initial).map(ScrollingLayout.Row.thumbWheel)
    #expect(onNothing != layout.advancedThumbWheelRows)
    // Swap directions reads All Mice's swap, which the mouse inherits.
    #expect(config.thumbWheel(at: path, base: ThumbWheelRows.base(config, scope)).reversed)
    // At the top level the wheel's own keys are the base: nothing under it.
    #expect(ThumbWheelRows.base(config, .global).reversed == false)
}

@Test func bothThumbWheelSectionsOfScrollingBuildOnAllMicesWheel() throws {
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI/ScrollingPane.swift"), encoding: .utf8)
    let calls = source.components(separatedBy: "ThumbWheelRows(").dropFirst()
    #expect(calls.count == 2)
    for call in calls { #expect(call.prefix(400).contains("base: ThumbWheelRows.base(config, scope)")) }
}

// MARK: Row captions

@MainActor @Test func captionSentencesJoinAsSeparateSentences() {
    let joined = RowLabel.caption(["Frees the wheel when you scroll fast", nil, ControlAvailability.unsupportedCaption])
    #expect(joined == "Frees the wheel when you scroll fast. Not supported by this mouse.")
    #expect(RowLabel.caption(["How far to turn.", RowLabel.mouseDefaultCaption, ControlAvailability.unsupportedCaption])
        == "How far to turn. Using the mouse's own setting. Not supported by this mouse.")
    // A lone caption stands as written, and nothing gives none.
    #expect(RowLabel.caption(["Reverses this wheel.", nil, nil]) == "Reverses this wheel.")
    #expect(RowLabel.caption([nil, nil, nil]) == nil)
}
