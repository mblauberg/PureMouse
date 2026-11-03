import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// The action picker's entries (`PickerEntry`, in the Settings view code).

@Test func anAppPickerOffersTheInheritedValueInsteadOfDefault() {
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
        #expect(text.contains("offersMouseDefault: PickerEntry.offersMouseDefault("), "\(file)")
        #expect(!text.contains("allowsDefault: false"), "\(file)")
    }
    // The one row both panes draw offers it on the click, while no other trigger applies, and never
    // on a child row (a table's click is PureMouse's, so its other triggers would go).
    let rows = try String(contentsOf: ui.appending(path: "TriggerRows.swift"), encoding: .utf8)
    #expect(rows.contains("allowsDefault: offersMouseDefault && !othersApply"))
    #expect(rows.components(separatedBy: "allowsDefault: false").count == 3)
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

// MARK: More Ways to Press (#158)

@Test func moreWaysToPressIsAtTheFootOfAClickRowsPicker() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
    let foot = entries.suffix(3)
    #expect(foot.map(\.id) == ["trigger.doubleClick", "trigger.hold", "gesture"])
    #expect(foot.map(\.label) == ["Double-Click", "Hold", "Hold and Move"])
    #expect(foot.allSatisfy { $0.group == "More Ways to Press" && !$0.isDisabled })
    #expect(foot.map(\.kind) == [.trigger("doubleClick"), .trigger("hold"), .gesture])
    // Nowhere else: Hold and Move is no longer a Custom action.
    #expect(!entries.contains { $0.group == "Custom" && $0.kind == .gesture })
    // A picker that adds no rows (a direction, the thumb wheel) has no such section.
    #expect(!PickerEntry.all(allowsDefault: false, allowsGesture: false).contains { $0.group == "More Ways to Press" })
}

@Test func preciseOnTheClickTurnsMoreWaysToPressOff() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, current: .named("precisePointer"),
                                  row: PickerEntry.Row(clickOwnsButton: true))
    let ways = entries.filter { $0.group == "More Ways to Press" }
    #expect(ways.count == 3 && ways.allSatisfy { $0.isDisabled && $0.caption == "Remove Hold first." })
    // The other way round: with Double-click or Hold set, the click cannot become Precise Pointer.
    let busy = PickerEntry.all(allowsDefault: true, allowsGesture: true, row: PickerEntry.Row(othersApply: true))
    #expect(entry("precisePointer", busy)?.isDisabled == true)
    #expect(entry("dragLock", busy)?.isDisabled == false)
}

@Test func aHoldRowsPickerOpensWithNoActionAndHoldAndMove() {
    let entries = PickerEntry.all(allowsDefault: false, allowsGesture: false, row: PickerEntry.Row(trigger: "hold"))
    #expect(entries.prefix(2).map(\.label) == [Triggers.noAction, "Hold and Move"])
    #expect(entries.prefix(2).map(\.kind) == [.set(.named("none")), .gesture])
    #expect(!entries.contains { $0.label == "Do Nothing" || $0.id == "default" || $0.group == "More Ways to Press" })
    #expect(entry("precisePointer", entries) != nil)
    // In a mouse or app, "Same as …" still leads.
    let inherited = ActionButton.inherited(.standard, inheriting: "Precise Pointer", source: InheritedScope.allMice, trigger: true)
    let scoped = PickerEntry.all(allowsDefault: false, allowsGesture: false, inherited: inherited, row: PickerEntry.Row(trigger: "hold"))
    #expect(scoped.prefix(3).map(\.id) == ["inherit", "none", "gesture"])
}

@Test func aDoubleClickOrDirectionRowReadsNoActionAndOffersNoWhileHeldAction() {
    for trigger in ["doubleClick", "up"] {
        let entries = PickerEntry.all(allowsDefault: false, allowsGesture: false, row: PickerEntry.Row(trigger: trigger))
        #expect(entry("none", entries)?.label == Triggers.noAction)
        #expect(entry("precisePointer", entries) == nil && entry("dragLock", entries) != nil)
        #expect(entry("gesture", entries) == nil)
    }
    // Nor does the thumb wheel, which Kit gives no while-held action.
    let wheel = PickerEntry.all(allowsDefault: false, allowsGesture: false, row: PickerEntry.Row(allowsWhileHeld: false))
    #expect(entry("precisePointer", wheel) == nil)
    #expect(ButtonAction.named("none").triggerLabel == "No Action" && ButtonAction.named("none").label == "Do Nothing")
    #expect(ActionButton.spokenValue(for: .named("none"), inheriting: nil, spokenInheriting: nil, trigger: true) == "No Action")
}

@Test func preciseAndDragLockSitUnderMouseWithTheirCaptions() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
    #expect(entry("precisePointer", entries)?.group == "Mouse")
    #expect(entry("precisePointer", entries)?.caption == "Slows the pointer while you hold the button.")
    #expect(entry("dragLock", entries)?.group == "Mouse")
    #expect(entry("dragLock", entries)?.caption == "Click to start dragging, click again to let go.")
}
