import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// The action picker's entries (`PickerEntry`, in the Settings view code).

@Test func anAppPickerOffersSameAsEverywhereInsteadOfDefault() {
    let entries = PickerEntry.all(allowsDefault: false, allowsGesture: true, inherited: ActionButton.inherited(.standard, everywhere: "Mission Control"))
    #expect(entries.first?.label == "Same as Everywhere")
    #expect(entries.first?.detail == "(Mission Control)")
    #expect(entries.first?.matches(.standard) == true)
    #expect(!entries.contains { $0.id == "default" })
}

// MARK: Mouse Default beside "Same as …"

private func entry(_ id: String, _ entries: [PickerEntry]) -> PickerEntry? { entries.first { $0.id == id } }

@MainActor @Test func aMouseOrAppPickerOffersMouseDefaultAsAValueOfItsOwnBesideSameAsEverywhere() {
    let inherited = ActionButton.inherited(.standard, everywhere: "Mute", source: InheritedScope.allMice)
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
    let mouse = ActionButton.inherited(.mouseDefault, everywhere: "Mute", source: InheritedScope.allMice)
    #expect(mouse.effective == "Mouse Default" && mouse.caption == "Set for this mouse.")
    let app = ActionButton.inherited(.mouseDefault, everywhere: "Mute")
    #expect(app.effective == "Mouse Default" && app.caption == "Set for this app.")
    #expect(ActionButton.spokenValue(for: .mouseDefault, everywhere: "Mute", spokenEverywhere: nil) == "Mouse Default")
    #expect(ActionButton.inherited(.standard, everywhere: "Mute").caption == nil)
}

@MainActor @Test func theMouseButtonsPaneWritesTheChoiceItOffers() throws {
    // ButtonsPane applies a picked entry with `bind(_:to:in:)` in the mouse's scope.
    let mouse = try #require(ConfigScope.device("mb03400000000"))
    var tree = ConfigTree(["buttons": ["back": "mute"]])
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true,
                                  inherited: ActionButton.inherited(.standard, everywhere: "Mute", source: InheritedScope.allMice))
    guard case .set(let native) = entry("default", entries)?.kind, case .set(let same) = entry("inherit", entries)?.kind else {
        Issue.record("entries"); return
    }
    tree.bind("back", to: native, in: mouse)
    #expect(tree.string(["devices", "mb03400000000", "buttons", "back"]) == "default")
    tree.bind("back", to: same, in: mouse)
    #expect(!tree.contains(["devices"]))
    #expect(tree.string(["buttons", "back"]) == "mute")
    // Under All Mice, Mouse Default removes the key.
    guard case .set(let global)? = entry("default", PickerEntry.all(allowsDefault: true, allowsGesture: true))?.kind else {
        Issue.record("global"); return
    }
    tree.bind("back", to: global)
    #expect(!tree.contains(["buttons", "back"]))
}

@MainActor @Test func theAppSheetWritesTheChoiceItOffers() throws {
    // AppSheet applies a picked entry with `bindInApp(_:button:to:)`.
    var tree = ConfigTree(["buttons": ["back": "mute"]])
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true,
                                  inherited: ActionButton.inherited(.standard, everywhere: "Mute"))
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
    for file in ["ButtonsPane.swift", "AppSheet.swift"] {
        let text = try String(contentsOf: ui.appending(path: file), encoding: .utf8)
        #expect(text.contains("allowsDefault: !isDirection,"), "\(file)")
        #expect(!text.contains("allowsDefault: false"), "\(file)")
    }
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

@Test func theHapticWaveformsShowUnlessTheMouseIsKnownToLackAMotor() {
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
    #expect(ActionButton.spokenValue(for: .keys("shift+cmd+4"), everywhere: nil, spokenEverywhere: nil) == "Shift Command 4")
    #expect(ActionButton.spokenValue(for: .keys("cmd+shift+4"), everywhere: nil, spokenEverywhere: nil) == "Shift Command 4")
    #expect(ActionButton.spokenValue(for: .standard, everywhere: nil, spokenEverywhere: nil) == "Mouse Default")
    #expect(ActionButton.spokenValue(for: .named("missionControl"), everywhere: nil, spokenEverywhere: nil)
        == ButtonAction.named("missionControl").label)
    // An app's own shortcut, and one it leaves to Everywhere, are both in words.
    #expect(ActionButton.spokenValue(for: .keys("ctrl+left"), everywhere: "⇧⌘4", spokenEverywhere: "Shift Command 4")
        == "Control Left")
    #expect(ActionButton.spokenValue(for: .standard, everywhere: "⇧⌘4", spokenEverywhere: "Shift Command 4")
        == "Shift Command 4, same as Everywhere")
    #expect(ButtonAction.keys("shift+cmd+4").spokenLabel != ButtonAction.keys("shift+cmd+4").label)
}

@MainActor @Test func aTooltipIsUnder75Characters() {
    #expect(ActionButton.tooltip(for: .keys("shift+cmd+4")) == "Presses ⇧⌘4")
    #expect(ActionButton.tooltip(for: .standard).isEmpty)
    let long = ActionButton.tooltip(for: .run(String(repeating: "open -a Safari ", count: 20)))
    #expect(long.count < 75 && long.hasPrefix("Runs: open") && long.contains("…"))
    #expect(ActionButton.tooltip(for: .run("open -a Safari")) == "Runs: open -a Safari")
}
