import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// The action picker's entries (`PickerEntry`, in the Settings view code).

@MainActor @Test func anAppPickerOffersTheInheritedValueInsteadOfDefault() {
    let entries = PickerEntry.all(allowsDefault: false, allowsGesture: true, inherited: ActionButton.inherited(.standard, inheriting: "Mission Control"))
    #expect(entries.first?.label == "Same as Mouse Settings")
    #expect(entries.first?.detail == "(Mission Control)")
    #expect(entries.first?.matches(.standard) == true)
    #expect(!entries.contains { $0.id == "default" })
}

// MARK: Mouse Default beside "Same as …"

private func entry(_ id: String, _ entries: [PickerEntry]) -> PickerEntry? { entries.first { $0.id == id } }

@MainActor @Test func aMouseOrAppPickerOffersMouseDefaultAsAValueOfItsOwnBesideTheInheritedValue() {
    let inherited = ActionButton.inherited(.standard, inheriting: "Mute", source: InheritedScope.allMice)
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, inherited: inherited)
    let same = entry("inherit", entries)
    let native = entry("default", entries)
    #expect(same?.label == "Same as All Mice" && same?.detail == "(Mute)")
    #expect(native?.label == "Mouse Default")
    // Two choices that write different things: one removes the key, the other writes "default".
    #expect(same?.kind == .set(.standard) && native?.kind == .set(.mouseDefault))
    #expect(same?.matches(.standard) == true && same?.matches(.mouseDefault) == false)
    #expect(native?.matches(.mouseDefault) == true && native?.matches(.standard) == false)
    // Under All Mice there is nothing to inherit: Mouse Default is the removed key.
    #expect(entry("default", PickerEntry.all(allowsDefault: true, allowsGesture: true))?.kind == .set(.standard))
    // A gesture direction offers neither.
    #expect(entry("default", PickerEntry.all(allowsDefault: false, allowsGesture: false, inherited: inherited)) == nil)
}

@MainActor @Test func aRowWhoseOwnValueIsMouseDefaultShowsItAndSaysItIsSet() {
    let mouse = ActionButton.inherited(.mouseDefault, inheriting: "Mute", source: InheritedScope.allMice)
    #expect(mouse.effective == "Mouse Default" && mouse.caption == "Set for this mouse.")
    let app = ActionButton.inherited(.mouseDefault, inheriting: "Mute")
    #expect(app.effective == "Mouse Default" && app.caption == "Set for this app.")
    #expect(ActionButton.spokenValue(for: .mouseDefault, inheriting: "Mute", spokenInheriting: nil) == "Mouse Default")
    #expect(ActionButton.inherited(.standard, inheriting: "Mute").caption == nil)
}

@MainActor @Test func theMouseButtonsPaneWritesTheChoiceItOffers() throws {
    // ButtonsPane applies a picked entry with `bind(_:to:in:)` in the mouse's scope.
    let mouse = try #require(ConfigScope.device("mb03400000000"))
    var tree = ConfigTree(["buttons": ["back": "mute"]])
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true,
                                  inherited: ActionButton.inherited(.standard, inheriting: "Mute", source: InheritedScope.allMice))
    guard case .set(let native) = entry("default", entries)?.kind, case .set(let same) = entry("inherit", entries)?.kind else {
        Issue.record("entries"); return
    }
    tree.bind("back", to: native, in: mouse)
    #expect(tree.string(["devices", "mb03400000000", "buttons", "back"]) == "default")
    tree.bind("back", to: same, in: mouse)
    #expect(!tree.contains(["devices"]))
    #expect(tree.string(["buttons", "back"]) == "mute")
    // Under All Mice, Mouse Default removes the key where the default set binds nothing, and
    // writes "default" where it binds something (Back), so the default set does not return.
    guard case .set(let global)? = entry("default", PickerEntry.all(allowsDefault: true, allowsGesture: true))?.kind else {
        Issue.record("global"); return
    }
    tree.bind("back", to: global)
    #expect(tree.string(["buttons", "back"]) == "default")
    tree.bind("middle", to: .named("mute"))
    tree.bind("middle", to: global)
    #expect(!tree.contains(["buttons", "middle"]))
}

@MainActor @Test func theAppPageWritesTheChoiceItOffers() throws {
    // AppPage applies a picked entry with `bindInApp(_:button:to:)`.
    var tree = ConfigTree(["buttons": ["back": "mute"]])
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true,
                                  inherited: ActionButton.inherited(.standard, inheriting: "Mute"))
    guard case .set(let native) = entry("default", entries)?.kind, case .set(let same) = entry("inherit", entries)?.kind else {
        Issue.record("entries"); return
    }
    tree.bindInApp("com.example.x", button: "back", to: native)
    #expect(tree.string(["apps", "com.example.x", "buttons", "back"]) == "default")
    tree.bindInApp("com.example.x", button: "back", to: same)
    #expect(!tree.hasApp("com.example.x"))
}

@Test func bothPanesOfferMouseDefaultOnAButtonRowAndNotOnADirection() throws {
    let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")
    for file in ["ButtonsPane.swift", "AppPage.swift"] {
        let text = try String(contentsOf: ui.appending(path: file), encoding: .utf8)
        // The button rows ask the one rule (`PickerEntry.offersMouseDefault`, tested by control in OverrideRowTests).
        #expect(text.contains("allowsDefault: !isDirection && PickerEntry.offersMouseDefault("), "\(file)")
        #expect(!text.contains("allowsDefault: false"), "\(file)")
    }
}

@Test func mediaAndMiddleClickLeadTheirPickerGroups() {
    let media = ActionCatalog.groups.first { $0.title == "Media" }
    let mouse = ActionCatalog.groups.first { $0.title == "Mouse" }
    #expect(Array(media?.names.prefix(3) ?? []) == ["playPause", "nextTrack", "previousTrack"])
    #expect(Array(mouse?.names.prefix(1) ?? []) == ["middleClick"])
    #expect(["playPause", "nextTrack", "previousTrack", "middleClick"].map(ActionCatalog.label(for:))
        == ["Play/Pause", "Next Track", "Previous Track", "Middle Click"])
    #expect(ActionCatalog.symbol(for: "playPause") == "playpause")
    #expect(ActionCatalog.symbol(for: "nextTrack") == "forward")
    #expect(ActionCatalog.symbol(for: "previousTrack") == "backward")
    #expect(ActionCatalog.symbol(for: "middleClick") == "cursorarrow.click")
}

@Test func thePickerListsEveryHapticWaveformInWords() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
        .filter { $0.group == ActionCatalog.hapticGroup }
    #expect(entries.map(\.kind) == HapticWaveform.allCases.map { .set(.haptic($0.rawValue)) })
    #expect(entries.allSatisfy { $0.symbol != nil })
    #expect(ActionCatalog.hapticLabel(for: "sharpStateChange") == "Sharp State Change")
    #expect(ActionCatalog.hapticLabel(for: "happyAlert") == "Happy Alert")
    #expect(ActionCatalog.hapticLabel(for: "boxBreathing") == "Box Breathing")
    #expect(ButtonAction.haptic("happyAlert").label == "Haptic: Happy Alert")
    #expect(ActionCatalog.hapticGroup.contains("MX Master 4"))
}

// MARK: Haptic gating

private func mouse(haptics: Bool?) -> Status.Device {
    Status.Device(id: "r1:1", name: "MX", connection: .receiver, online: true, battery: nil, dpi: nil, dpiSteps: [],
                  wheelMode: nil, controls: [], capabilities: .init(haptics: haptics))
}

@MainActor @Test func theHapticWaveformsShowUnlessTheMouseIsKnownToLackAMotor() {
    let unbound = ButtonAction.named("mute")
    // Known to lack it: hidden. Known to have it, or unknown, or no mouse: shown.
    #expect(!ActionButton.offersHaptics(for: unbound, devices: [mouse(haptics: false)]))
    #expect(ActionButton.offersHaptics(for: unbound, devices: [mouse(haptics: true)]))
    #expect(ActionButton.offersHaptics(for: unbound, devices: [mouse(haptics: nil)]))
    #expect(ActionButton.offersHaptics(for: unbound, devices: []))
    // A waveform already bound keeps them listed, so the choice can be seen and changed.
    #expect(ActionButton.offersHaptics(for: .haptic("happyAlert"), devices: [mouse(haptics: false)]))
}

// MARK: Spoken value and tooltip

@MainActor @Test func aShortcutBindingIsReadAsWordsNotGlyphs() {
    #expect(ActionButton.spokenValue(for: .keys("shift+cmd+4"), inheriting: nil, spokenInheriting: nil) == "Shift Command 4")
    #expect(ActionButton.spokenValue(for: .keys("cmd+shift+4"), inheriting: nil, spokenInheriting: nil) == "Shift Command 4")
    #expect(ActionButton.spokenValue(for: .standard, inheriting: nil, spokenInheriting: nil) == "Mouse Default")
    #expect(ActionButton.spokenValue(for: .named("missionControl"), inheriting: nil, spokenInheriting: nil)
        == ButtonAction.named("missionControl").label)
    // An app's own shortcut, and one it leaves to the wider scope, are both in words.
    #expect(ActionButton.spokenValue(for: .keys("ctrl+left"), inheriting: "⇧⌘4", spokenInheriting: "Shift Command 4")
        == "Control Left")
    #expect(ActionButton.spokenValue(for: .standard, inheriting: "⇧⌘4", spokenInheriting: "Shift Command 4")
        == "Shift Command 4, same as Mouse Settings")
    #expect(ButtonAction.keys("shift+cmd+4").spokenLabel != ButtonAction.keys("shift+cmd+4").label)
}

@MainActor @Test func aTooltipIsUnder75Characters() {
    #expect(ActionButton.tooltip(for: .keys("shift+cmd+4")) == "Presses ⇧⌘4")
    #expect(ActionButton.tooltip(for: .standard).isEmpty)
    let long = ActionButton.tooltip(for: .run(String(repeating: "open -a Safari ", count: 20)))
    #expect(long.count < 75 && long.hasPrefix("Runs: open") && long.contains("…"))
    #expect(ActionButton.tooltip(for: .run("open -a Safari")) == "Runs: open -a Safari")
}

// MARK: Action Packs (Issue #154)

@MainActor @Test func appFirstPickerListsAppActionsBeforeGenericGroups() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos")
    let packEntries = entries.filter(\.isPackAction)
    #expect(!packEntries.isEmpty)
    #expect(packEntries.allSatisfy { $0.appName == "Zoom" })

    // Pack actions come before generic groups (e.g. desktop, media)
    let firstPackIndex = entries.firstIndex { $0.isPackAction }!
    let firstGenericIndex = entries.firstIndex { $0.id == "missionControl" }!
    #expect(firstPackIndex < firstGenericIndex)

    // First entries are the top entries (default, none)
    #expect(entries[0].id == "default")
    #expect(entries[1].id == "none")
    #expect(entries[2].isPackAction)

    // Trailing shortcut text is populated
    let muteEntry = entries.first { $0.id == "zoom.muteAudio" }!
    #expect(muteEntry.shortcutText == "⇧⌘A")
}

@MainActor @Test func appWithoutPackHasNoPackActions() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "com.unknown.app")
    #expect(!entries.contains { $0.isPackAction })
}

@MainActor @Test func sectionFoldingAndFlatSearch() {
    let dummyEntries = (1...8).map { i in
        PickerEntry(id: "item\(i)", label: "Item \(i)", group: "Test Group", kind: .set(.named("item\(i)")))
    }

    // Folded: 5 items + 1 showAll item
    let folded = PickerItem.visible(dummyEntries, query: "", hapticsOpen: false, expandedSections: [], app: nil)
    #expect(folded.count == 6)
    if case .showAll(let title, let total) = folded.last {
        #expect(title == "Test Group")
        #expect(total == 8)
    } else {
        Issue.record("Expected showAll item at end of folded section")
    }

    // Expanded: all 8 items
    let expanded = PickerItem.visible(dummyEntries, query: "", hapticsOpen: false, expandedSections: ["Test Group"], app: nil)
    #expect(expanded.count == 8)

    // Search query: folding is ignored
    let searchResults = PickerItem.visible(dummyEntries, query: "item", hapticsOpen: false, expandedSections: [], app: nil)
    #expect(searchResults.count == 8)

    // Search in Mouse scope (app == nil) matching pack action shows hint
    let mouseHintResults = PickerItem.visible([], query: "brush", hapticsOpen: false, expandedSections: [], app: nil)
    #expect(mouseHintResults.contains {
        if case .packHint(let text) = $0 {
            return text.contains("Adobe Photoshop") && text.contains("Choose them on the app's page.")
        }
        return false
    })
}

@MainActor @Test func pickingPackActionWritesOrdinaryBinding() throws {
    var tree = ConfigTree()
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos")
    let muteEntry = entries.first { $0.id == "zoom.muteAudio" }!
    guard case .set(let action) = muteEntry.kind else {
        Issue.record("Expected .set kind")
        return
    }

    // Applies to tree using standard config tree binding
    tree.bindInApp("us.zoom.xos", button: "back", to: action)

    // Verify ordinary binding was written: keys = "cmd+shift+a"
    #expect(tree.string(["apps", "us.zoom.xos", "buttons", "back", "keys"]) == "cmd+shift+a")

    // The written config contains no reference to catalogue or action ID
    let jsonString = String(decoding: tree.data(), as: UTF8.self)
    #expect(!jsonString.contains("zoom.muteAudio"))
    #expect(!jsonString.contains("ActionPack"))
}

@MainActor @Test func displayNameResolution() {
    // Stored binding equal to pack action displays pack name
    #expect(ActionButton.displayName(for: .keys("cmd+shift+a"), in: "us.zoom.xos") == "Mute or Unmute Microphone")

    // Unrelated shortcut in pack app displays ordinary shortcut
    #expect(ActionButton.displayName(for: .keys("cmd+shift+9"), in: "us.zoom.xos") == "⇧⌘9")

    // App without pack displays ordinary shortcut
    #expect(ActionButton.displayName(for: .keys("cmd+shift+a"), in: "com.unknown.app") == "⇧⌘A")

    // Spoken value for pack action uses pack action label
    let spoken = ActionButton.spokenValue(for: .keys("cmd+shift+a"), in: "us.zoom.xos", inheriting: nil, spokenInheriting: nil)
    #expect(spoken == "Mute or Unmute Microphone")
}

@MainActor @Test func layoutKeymapDependentHelpNote() {
    // Final Cut Pro blade cut action has keymap note
    let fcpTooltip = ActionButton.tooltip(for: .keys("cmd+b"), in: "com.apple.FinalCut")
    #expect(fcpTooltip == "Depends on your keymap.")

    // Standard pack action without keymap note has standard tooltip
    let zoomTooltip = ActionButton.tooltip(for: .keys("cmd+shift+a"), in: "us.zoom.xos")
    #expect(zoomTooltip == "Presses ⇧⌘A")
}

@MainActor @Test func thumbWheelPackPairWritesOrdinaryBindingsAndRecognizesChoice() {
    var tree = ConfigTree()
    let pairs = ActionPackCatalog.shared.resolvedThumbWheelPairs(for: "com.adobe.Photoshop")
    let pair = ActionPackCatalog.shared.pairs(for: "com.adobe.Photoshop").first { $0.label == "Brush Size" }!
    let choice = ThumbWheelChoice.packPair(id: pair.id, label: pair.label)

    tree.chooseThumbWheel(choice, at: ["apps", "com.adobe.Photoshop", "thumbWheel"], pairs: pairs)

    // Ordinary bindings written for left and right
    #expect(tree.string(["apps", "com.adobe.Photoshop", "thumbWheel", "left", "keys"]) == "[")
    #expect(tree.string(["apps", "com.adobe.Photoshop", "thumbWheel", "right", "keys"]) == "]")

    // ConfigTree resolves ordinary bindings back into pack pair choice
    let resolved = tree.thumbWheelChoice(at: ["apps", "com.adobe.Photoshop", "thumbWheel"], pairs: pairs)
    #expect(resolved == choice)
}

