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

@MainActor @Test func theAppsSectionFoldsAndSearchIgnoresFolding() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, haptics: false, app: "us.zoom.xos")
    let pack = entries.filter(\.isPackAction)
    #expect(pack.count == 8 && pack.allSatisfy { $0.group == "Zoom" })

    // Folded: five rows, then Show All (8) in their place.
    let folded = PickerItem.visible(entries, query: "", hapticsOpen: false, app: "us.zoom.xos")
    #expect(folded.filter { if case .entry(let e) = $0 { e.isPackAction } else { false } }.count == 5)
    #expect(folded.contains(.showAll(section: "Zoom", count: 8)))
    #expect(PickerItem.showAll(section: "Zoom", count: 8).section == "Zoom")

    // Open: all eight, no Show All.
    let open = PickerItem.visible(entries, query: "", hapticsOpen: false, expandedSections: ["Zoom"], app: "us.zoom.xos")
    #expect(open.filter { if case .entry(let e) = $0 { e.isPackAction } else { false } }.count == 8)
    #expect(!open.contains { if case .showAll = $0 { true } else { false } })

    // A search shows every match whatever is folded, and keeps the sections.
    let found = PickerItem.visible(entries, query: "meeting", hapticsOpen: false, app: "us.zoom.xos")
    #expect(found.count == 7)
    #expect(found.allSatisfy { $0.section == "Zoom" })

    // The sheet opens the section holding the current binding.
    #expect(PickerItem.sectionsHolding(.keys("cmd+shift+f"), in: entries) == ["Zoom"])
    #expect(PickerItem.sectionsHolding(.keys("cmd+shift+9"), in: entries).isEmpty)
}

@MainActor @Test func everyOtherSectionAndPageListsAsBefore() {
    // Generic sections never fold, however long.
    let long = (1...8).map { PickerEntry(id: "item\($0)", label: "Item \($0)", group: "Test Group", kind: .set(.named("item\($0)"))) }
    #expect(PickerItem.visible(long, query: "", hapticsOpen: false).count == 8)

    // An app without a pack, and Mouse scope, get the entries and rows they always had.
    let plain = PickerEntry.all(allowsDefault: true, allowsGesture: true)
    let unknown = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "com.unknown.app")
    #expect(unknown == plain)
    #expect(PickerItem.visible(unknown, query: "", hapticsOpen: false, app: "com.unknown.app")
            == PickerItem.visible(plain, query: "", hapticsOpen: false))
    #expect(!plain.contains { $0.isPackAction })

    // A pack's actions are not in a plain page's search, and its haptic group stays where it was.
    #expect(!PickerItem.visible(plain, query: "brush", hapticsOpen: false).contains { if case .entry = $0 { true } else { false } })
    let withPack = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos")
    let items = PickerItem.visible(withPack, query: "", hapticsOpen: false, app: "us.zoom.xos")
    let haptic = items.firstIndex(of: .hapticGroup(expanded: false))!
    #expect(items[haptic + 1].id == "keys")
    // Search keeps the section headers of a plain page.
    #expect(PickerItem.visible(plain, query: "zoom", hapticsOpen: false).allSatisfy { $0.section == "Tabs and Zoom" })
}

@MainActor @Test func mouseScopeHintsAtAppsWhoseActionsMatch() {
    let hint = PickerItem.visible([], query: "brush", hapticsOpen: false)
    #expect(hint.contains {
        if case .packHint(let text) = $0 { text.contains("Adobe Photoshop") && text.contains("Choose them on the app's page.") } else { false }
    })
    // Not on an app's page, and not when something matched.
    #expect(PickerItem.visible([], query: "brush", hapticsOpen: false, app: "us.zoom.xos").isEmpty)
    #expect(PickerItem.visible(PickerEntry.all(allowsDefault: true, allowsGesture: true), query: "mute", hapticsOpen: false)
        .allSatisfy { if case .packHint = $0 { false } else { true } })
}

@MainActor @Test func thePickerSearchesPackActionsWithTheCataloguesMatcher() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos")
    func found(_ query: String) -> Set<String> {
        Set(PickerItem.visible(entries, query: query, hapticsOpen: false, app: "us.zoom.xos").map(\.id)).intersection(["zoom.muteAudio"])
    }
    // The shortcut as words in any order, as a spec and as glyphs.
    for query in ["command shift a", "shift cmd a", "shift+cmd+a", "⇧⌘A", "cmd+shift+a"] {
        #expect(found(query) == ["zoom.muteAudio"], "\(query)")
    }
    // Keywords match whole words only.
    #expect(found("talk") == ["zoom.muteAudio"])
    #expect(found("tal").isEmpty)
    #expect(found("microph") == ["zoom.muteAudio"])  // the label has it as a substring
    // The label, category and app name, as anywhere.
    #expect(found("unmute") == ["zoom.muteAudio"])
    #expect(found("zoom") == ["zoom.muteAudio"])
    // A search for what it does not hold finds none of the pack.
    #expect(found("photoshop").isEmpty)
    // Searching shows where the action lives.
    let item = PickerItem.visible(entries, query: "talk", hapticsOpen: false, app: "us.zoom.xos").first
    if case .entry(let entry)? = item { #expect(entry.detail == "Meeting") } else { Issue.record("no row") }
}

@MainActor @Test func aKeymapDependentRowSaysSoInSecondaryText() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "com.apple.FinalCut")
    let blade = entries.first { $0.id == "finalcut.blade" }!
    #expect(blade.note == "Depends on your keymap")
    #expect(blade.shortcutText == "⌘B")
    // Rows whose shortcut is the app's own fixed one say nothing.
    #expect(PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos").filter(\.isPackAction).allSatisfy { $0.note == nil })
    // A bound row is ticked whichever way the shortcut is spelled.
    #expect(blade.matches(.keys("cmd+b")))
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

@MainActor @Test func theAppPageTooltipKeepsTheShortcut() {
    #expect(ActionButton.tooltip(for: .keys("cmd+b"), in: "com.apple.FinalCut") == "Presses ⌘B. Depends on your keymap.")
    #expect(ActionButton.tooltip(for: .keys("cmd+shift+a"), in: "us.zoom.xos") == "Presses ⇧⌘A")
    #expect(ActionButton.tooltip(for: .keys("cmd+b"), in: "com.unknown.app") == "Presses ⌘B")
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


private func populated() -> [String: Any] { [
    "dpi": 1600,
    "buttons": ["back": "mute", "forward": ["keys": "cmd+]"]],
    "thumbWheel": ["action": "zoom", "step": 4],
    "devices": ["mx-master-3s": ["name": "MX Master 3S", "buttons": ["middle": "mute"]]],
    "apps": [
        "com.other.app": ["buttons": ["back": "volumeUp"], "thumbWheel": ["action": "tabs"]],
        "us.zoom.xos": ["buttons": ["forward": "nextTab"], "thumbWheel": ["reversed": true]],
    ],
] }

private func json(_ tree: ConfigTree) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: tree.data())) as? NSDictionary ?? [:]
}

@MainActor @Test func pickingAPackActionLeavesEveryOtherFieldUntouched() throws {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, app: "us.zoom.xos")
    guard case .set(let action) = entries.first(where: { $0.id == "zoom.muteAudio" })!.kind else {
        Issue.record("not a binding"); return
    }
    var tree = ConfigTree(populated())
    let before = json(tree)
    tree.bindInApp("us.zoom.xos", button: "back", to: action)

    // One new key, an ordinary binding; take it away and the tree is what it was.
    #expect(tree.string(["apps", "us.zoom.xos", "buttons", "back", "keys"]) == "cmd+shift+a")
    var after = tree
    after.set(nil, at: ["apps", "us.zoom.xos", "buttons", "back"])
    #expect(json(after) == before)
    #expect(!String(decoding: tree.data(), as: UTF8.self).contains("zoom.muteAudio"))
}

@MainActor @Test func aCatalogueChangeLeavesSavedBindingsAlone() throws {
    func catalogue(payload: String) -> ActionPackCatalog {
        let actions = (1...6).map { i in
            ActionPackEntry(id: "app.a\(i)", bundleIDs: ["com.example.app"], label: "Action \(i)", category: "Test",
                            payload: i == 1 ? payload : "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        return ActionPackCatalog(data: ActionCatalogData(packs: [ActionPack(id: "app", name: "App", bundleIDs: ["com.example.app"], actions: actions)]))
    }
    let old = catalogue(payload: "cmd+shift+a")
    // The user picked Action 1 under the old catalogue.
    var tree = ConfigTree(populated())
    tree.bindInApp("com.example.app", button: "back", to: old.action(matching: .keys("cmd+shift+a"), in: "com.example.app")!.buttonAction)
    let saved = tree.data()

    // The update moves it. Nothing is written, and the saved shortcut is read back as it was: it no
    // longer names the action, so Settings shows the shortcut as typed.
    let updated = catalogue(payload: "cmd+opt+a")
    #expect(tree.data() == saved)
    #expect(tree.string(["apps", "com.example.app", "buttons", "back", "keys"]) == "cmd+shift+a")
    #expect(updated.action(matching: .keys("cmd+shift+a"), in: "com.example.app") == nil)
    #expect(updated.action(matching: .keys("cmd+opt+a"), in: "com.example.app")?.id == "app.a1")
}

@MainActor @Test func aPackPairSwapsWithTheDirectionsAndFollowsInheritance() throws {
    let app = "com.apple.FinalCut"
    let path = ["apps", app, "thumbWheel"]
    let pairs = ActionPackCatalog.shared.resolvedThumbWheelPairs(for: app)
    let zoom = try #require(pairs.first { $0.label == "Zoom Timeline" })
    // Turning left zooms out: the pair's first action.
    #expect(zoom.left == .keys("cmd+-") && zoom.right == .keys("cmd+="))
    let choice = ThumbWheelChoice.packPair(id: zoom.id, label: zoom.label)

    var tree = ConfigTree(populated())
    let global = tree.thumbWheel(at: ["thumbWheel"])
    #expect(tree.thumbWheelChoice(at: path, pairs: pairs) == .inherit)
    tree.chooseThumbWheel(choice, at: path, base: global, pairs: pairs)
    #expect(tree.thumbWheelChoice(at: path, pairs: pairs) == choice)
    var state = tree.thumbWheel(at: path, base: global)
    #expect(state.pair?.left == .keys("cmd+-") && state.pair?.right == .keys("cmd+="))
    // The global zoom preset's step is not inherited into custom keys (the step key is cleared).
    #expect(tree.string(path + ["left", "keys"]) == "cmd+-" && tree.string(path + ["right", "keys"]) == "cmd+=")

    // Swap directions flips which way each does, without touching the pair, and the choice stays.
    tree.setThumbWheelReversed(true, at: path)
    state = tree.thumbWheel(at: path, base: global)
    #expect(state.reversed && state.pair?.left == .keys("cmd+-") && state.pair?.right == .keys("cmd+="))
    #expect(ConfigTree.thumbWheelKey(turning: "left", reversed: true) == "right")
    #expect(tree.thumbWheelChoice(at: path, pairs: pairs) == choice)

    // Same as Mouse Settings gives it back: the keys go, the other apps and the top level stay.
    let others = json(tree)
    tree.chooseThumbWheel(.inherit, at: path, base: global, pairs: pairs)
    #expect(tree.thumbWheelChoice(at: path, pairs: pairs) == .inherit)
    #expect(!tree.contains(path + ["left"]) && !tree.contains(path + ["right"]))
    #expect((json(tree)["thumbWheel"] as? NSDictionary) == (others["thumbWheel"] as? NSDictionary))
    let otherApp = { (tree: NSDictionary) in (tree["apps"] as? NSDictionary)?["com.other.app"] as? NSDictionary }
    #expect(otherApp(json(tree)) == otherApp(others))
    // A hand-edited pair in the other order is Custom, not the pack's.
    tree.setThumbWheel("left", to: zoom.right, at: path)
    tree.setThumbWheel("right", to: zoom.left, at: path)
    #expect(tree.thumbWheelChoice(at: path, pairs: pairs) == .custom)
}

@MainActor @Test func theBrowserPacksOfferNoSwitchTabsPair() {
    for app in ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac"] {
        #expect(ActionPackCatalog.shared.pairs(for: app).isEmpty, "\(app)")
    }
}
