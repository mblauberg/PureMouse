import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// A mouse's and an app's rows, one by one: what each says about the value it has (docs/ui-language.md,
// "A value left to a wider scope"). The views take these answers; nothing here draws.

private let mouseKey = "mb03400000000"

private func tree(_ json: String) throws -> ConfigTree {
    try ConfigTree(data: Data(json.utf8))
}

private func mouse() throws -> ConfigScope { try #require(ConfigScope.device(mouseKey)) }

@MainActor private func wheel(_ config: ConfigTree, inherited: ThumbWheelChoice?, scope: ConfigScope) -> ThumbWheelPresentation {
    let path = config.prefix(of: scope) + ["thumbWheel"]
    return ThumbWheelPresentation(config: config, path: path, base: ThumbWheelRows.base(config, scope), inherited: inherited,
                                  source: InheritedScope.allMice, scope: scope)
}

// MARK: Standing and the spoken value

@MainActor @Test func aMouseRowIsOwnWhileTheMouseHoldsTheKeyAndSaysSoOnlyThen() throws {
    let config = try tree(#"{"smoothScroll": {"speed": 1.5}, "devices": {"\#(mouseKey)": {"name": "MX", "smoothScroll": {"speed": 2}}}}"#)
    let own = RowStanding.of([["smoothScroll", "speed"]], in: config, scope: try mouse())
    let left = RowStanding.of([["smoothScroll", "acceleration"]], in: config, scope: try mouse())
    #expect(own.isOwn && own.note?.caption == "Set for this mouse." && own.spoken("2.0x") == "2.0x")
    #expect(!left.isOwn && left.note == nil && left.isInherited)
    // Left to All Mice, a switch, a segment and a slider each say where the value comes from.
    #expect(left.spoken("On") == "On, same as All Mice")
    // All Mice has nothing wider.
    let top = RowStanding.of([["smoothScroll", "speed"]], in: config, scope: .global)
    #expect(top.note == nil && !top.isInherited && top.spoken("On") == "On")
}

@MainActor @Test func everyChangedRowsLinkNamesItsRow() throws {
    let note = try #require(InheritedValue(own: 1, inherited: 2, source: InheritedScope.allMice).note {})
    let speed = OverrideLine.spokenReset(note, subject: "Scrolling speed")
    let feel = OverrideLine.spokenReset(note, subject: "Feel")
    #expect(speed == "Use All Mice Setting for Scrolling speed" && speed != feel)
}

// MARK: The thumb wheel

@MainActor @Test func aMouseThatInheritsACustomWheelShowsItsTurnRowsAndTurnDistance() throws {
    let config = try tree(#"{"thumbWheel": {"left": "volumeDown", "right": "volumeUp", "step": 6}}"#)
    let scope = try mouse()
    let presentation = wheel(config, inherited: .custom, scope: scope)
    #expect(presentation.choice == .inherit && presentation.effective == .custom)
    #expect(presentation.showsDirections)
    #expect(presentation.state.step == 6)
    let rows = ThumbWheelRows.advancedRows(config, path: config.prefix(of: scope) + ["thumbWheel"], base: presentation.base)
    #expect(rows.contains(.turnDistance) && rows.contains(.swapDirections))
    // Nothing is the mouse's own, so nothing is marked.
    for key in ["left", "right", "step", "reversed"] { #expect(presentation.standing(of: key).note == nil, "\(key)") }
    #expect(presentation.direction("left").caption == nil)
    #expect(presentation.direction("left").effective == presentation.direction("left").inherited)
}

@MainActor @Test func aMouseThatSetsTheTurnDistanceMarksItAndGivesItBack() throws {
    let config = try tree(#"{"thumbWheel": {"action": "zoom"}, "devices": {"\#(mouseKey)": {"name": "MX", "thumbWheel": {"step": 9}}}}"#)
    let presentation = wheel(config, inherited: .preset("zoom"), scope: try mouse())
    // The action is the preset's; only the distance is the mouse's.
    #expect(presentation.choice == .inherit && presentation.effective == .preset("zoom"))
    #expect(presentation.state.step == 9)
    var removed = 0
    let step = presentation.standing(of: "step") { removed += 1 }
    #expect(step.note?.caption == "Set for this mouse." && step.note?.resetTitle == "Use All Mice Setting")
    step.note?.reset()
    #expect(removed == 1)
    #expect(presentation.standing(of: "reversed").note == nil)
    #expect(presentation.action?.caption == nil)
}

@MainActor @Test func aMouseThatSetsOneTurnDirectionMarksThatOneAndKeepsTheOtherFromAllMice() throws {
    let config = try tree(#"""
        {"thumbWheel": {"left": "volumeDown", "right": "volumeUp"},
         "devices": {"\#(mouseKey)": {"name": "MX", "thumbWheel": {"left": "mute"}}}}
        """#)
    let presentation = wheel(config, inherited: .custom, scope: try mouse())
    let left = presentation.direction("left"), right = presentation.direction("right")
    #expect(left.caption == "Set for this mouse." && left.effective == ButtonAction.named("mute").label)
    #expect(left.inherited == ButtonAction.named("volumeDown").label)
    #expect(right.caption == nil && right.effective == ButtonAction.named("volumeUp").label)
    #expect(presentation.standing(of: "left").note != nil && presentation.standing(of: "right").note == nil)
}

@MainActor @Test func anAppThatInheritsAPresetShowsNoTurnRowsButStillOwnsItsDistance() throws {
    let config = try tree(#"{"thumbWheel": {"action": "tabs"}, "apps": {"com.example.x": {"thumbWheel": {"step": 4}}}}"#)
    let app = ConfigTree.appScope("com.example.x")
    let path = app.prefix + ["thumbWheel"]
    let presentation = ThumbWheelPresentation(config: config, path: path, base: config.thumbWheel(at: ["thumbWheel"]),
                                              inherited: .preset("tabs"), source: InheritedScope.mouseSettings, scope: .global)
    #expect(!presentation.showsDirections && presentation.effective == .preset("tabs"))
    #expect(presentation.standing(of: "step").note?.caption == "Set for this app.")
    #expect(ThumbWheelRows.advancedRows(config, path: path, base: presentation.base).contains(.turnDistance))
}

@MainActor @Test func theTopLevelWheelHasNothingToInheritFrom() throws {
    let config = try tree(#"{"thumbWheel": {"left": "volumeDown", "right": "volumeUp", "step": 6}}"#)
    let presentation = wheel(config, inherited: nil, scope: .global)
    #expect(presentation.action == nil && presentation.showsDirections)
    for key in ["left", "right", "step"] { #expect(presentation.standing(of: key).note == nil, "\(key)") }
}

// MARK: Gesture directions

@MainActor @Test func aDirectionTheMouseSetsIsMarkedWhetherOrNotAllMiceHasAGesture() throws {
    let scope = try mouse()
    // All Mice binds the button to a plain action; the mouse makes it a gesture with one direction.
    let plain = try tree(#"{"buttons": {"gesture": "mute"}, "devices": {"\#(mouseKey)": {"name": "MX", "buttons": {"gesture": {"up": "launchpad"}}}}}"#)
    let up = try #require(plain.scopedButton("gesture", in: scope).directions.first { $0.name == "up" })
    let down = try #require(plain.scopedButton("gesture", in: scope).directions.first { $0.name == "down" })
    #expect(up.isOwn && up.everywhere == nil)
    #expect(ActionButton.inherited(up, source: InheritedScope.allMice).caption == "Set for this mouse.")
    #expect(!down.isOwn && ActionButton.inherited(down, source: InheritedScope.allMice).caption == nil)
    // Left out, a direction does nothing when there is no wider gesture.
    #expect(down.inherited == .named("none"))
    // With a wider gesture the unset direction shows that one.
    let wide = try tree(#"{"buttons": {"gesture": {"up": "missionControl"}}, "devices": {"\#(mouseKey)": {"name": "MX", "buttons": {"gesture": {"down": "mute"}}}}}"#)
    let state = wide.scopedButton("gesture", in: scope)
    let wideUp = try #require(state.directions.first { $0.name == "up" })
    #expect(!wideUp.isOwn && wideUp.inherited == .named("missionControl"))
    #expect(try #require(state.directions.first { $0.name == "down" }).isOwn)
}

@MainActor @Test func anAppsOwnDirectionIsMarkedToo() throws {
    let config = try tree(#"{"apps": {"com.example.x": {"buttons": {"back": {"left": "mute"}}}}}"#)
    let state = config.appButton("com.example.x", button: "back")
    let left = try #require(state.directions.first { $0.name == "left" })
    #expect(ActionButton.inherited(left, source: InheritedScope.mouseSettings).caption == "Set for this app.")
    #expect(ActionButton.inherited(left, source: InheritedScope.mouseSettings).resetTitle == "Use Mouse Setting")
}

// MARK: Mouse Default

@MainActor @Test func aMouseOrAppOffersMouseDefaultOnlyForControlsWithABehaviourOfTheirOwn() {
    for name in ["middle", "back", "forward", "top"] {
        #expect(PickerEntry.offersMouseDefault(for: name, inMouseOrApp: true), "\(name)")
    }
    for name in ["gesture", "thumbPanel", "0x00c5"] {
        #expect(!PickerEntry.offersMouseDefault(for: name, inMouseOrApp: true), "\(name)")
        // Under All Mice it is just an unbound button.
        #expect(PickerEntry.offersMouseDefault(for: name, inMouseOrApp: false), "\(name)")
    }
    // A "default" already written stays visible and changeable.
    #expect(PickerEntry.offersMouseDefault(for: "gesture", inMouseOrApp: true, current: .mouseDefault))
    // The answer is the Kit table's: every control it names is offered, and no other.
    for cid in UInt16(0)...0x0200 {
        let key = String(format: "0x%04x", cid)
        #expect(PickerEntry.offersMouseDefault(for: key, inMouseOrApp: true) == (Config.nativeBehaviour(of: cid) != nil), "\(key)")
    }
}

@MainActor @Test func theMouseDefaultEntryIsHiddenWhereTheWiderScopeAlreadyIsMouseDefault() {
    let wideDefault = ActionButton.inherited(.standard, inheriting: ButtonAction.standard.label, source: InheritedScope.allMice)
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true, inherited: wideDefault)
    #expect(entries.first?.label == "Same as All Mice" && entries.first?.detail == "(Mouse Default)")
    #expect(!entries.contains { $0.id == "default" })
    // Where the wider scope binds something, both stay: they write different things.
    let wideMute = ActionButton.inherited(.standard, inheriting: "Mute", source: InheritedScope.allMice)
    #expect(PickerEntry.all(allowsDefault: true, allowsGesture: true, inherited: wideMute).contains { $0.id == "default" })
    // A "default" the scope already holds keeps its entry, so the row shows what is chosen.
    #expect(PickerEntry.all(allowsDefault: true, allowsGesture: true, inherited: wideDefault, current: .mouseDefault)
        .contains { $0.id == "default" })
}

// MARK: Captions

@MainActor @Test func feelKeepsItsNoPresetCaptionBesideTheChangeLine() {
    let note = InheritedValue(own: 1, inherited: 2, source: InheritedScope.allMice).note {}
    let caption = Feel.caption(for: nil)
    #expect(RowLabel("Feel", help: caption, note: note).captionText == nil)
    #expect(RowLabel("Feel", help: caption, note: note, keepsHelp: true).captionText == "Custom. Adjust in Advanced.")
}
