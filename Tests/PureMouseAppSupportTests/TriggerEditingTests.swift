import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

/// Settings' writes for a button's triggers (#158, ADR 24), checked against what Kit decodes: a
/// click keeps the other triggers, a bare action is written only when none applies, "No Action"
/// turns an inherited trigger off, one hold form replaces the other, and the default set never fills
/// a removed trigger back in.
@Suite struct TriggerEditingTests {
    private static let mouse = "m0123456789ab"
    private static let app = "com.example.x"
    private static let forward: UInt16 = 0x0056
    private static let gestureButton: UInt16 = 0x00C3

    private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
    private func decode(_ tree: ConfigTree) throws -> Config { try JSONDecoder().decode(Config.self, from: tree.data()) }
    private var device: ConfigScope { ConfigScope.device(Self.mouse)! }
    private var app: ConfigScope { .app(Self.app) }

    private func table(_ binding: Config.Binding?) -> Config.Binding.Gesture? {
        if case .gesture(let table)? = binding { table } else { nil }
    }

    /// The file a Settings write leaves: the edit replayed onto `file` as `ConfigStore` saves it, from
    /// the tree the panes read (laid over the default set).
    private func saved(_ file: ConfigTree, _ edit: (inout ConfigTree) -> Void) -> ConfigTree {
        let before = file.layered()
        var after = before
        edit(&after)
        var out = file
        out.apply(before.changes(to: after))
        return out
    }

    @Test func aClickChosenBesideAnotherTriggerGoesIntoTheTableAndTheBareFormComesBackWithout() throws {
        var config = try tree(#"{"buttons": {"forward": "navigateForward"}}"#)
        config.bindTrigger("forward", "doubleClick", to: .named("missionControl"))
        #expect(config[["buttons", "forward"]] as? NSDictionary == ["click": "navigateForward", "doubleClick": "missionControl"])
        config.bindClick("forward", to: .named("mute"))
        #expect(config[["buttons", "forward"]] as? NSDictionary == ["click": "mute", "doubleClick": "missionControl"])
        let decoded = try #require(table(try decode(config).bindings[Self.forward]))
        #expect(decoded.click == .mute && decoded.doubleClick == .missionControl)
        // No Action at the top level removes the trigger; with the click alone left, the bare form.
        config.bindTrigger("forward", "doubleClick", to: .named("none"))
        #expect(config.string(["buttons", "forward"]) == "mute")
    }

    @Test func aMouseOrAppWritesTheBareClickOnlyWhenNoOtherTriggerApplies() throws {
        var config = try tree("""
            {"buttons": {"forward": {"click": "navigateForward", "hold": "missionControl"}, "back": "navigateBack"}}
            """)
        // A wider hold applies: the click goes into the app's table, and the hold still applies.
        config.bindClick("forward", to: .named("mute"), in: app)
        #expect(config[["apps", Self.app, "buttons", "forward"]] as? NSDictionary == ["click": "mute"])
        let inApp = try #require(table(try decode(config).settings(forApp: Self.app)?.bindings[Self.forward]))
        #expect(inApp.click == .mute && inApp.hold == .missionControl)
        // Nothing else applies to Back: the bare action.
        config.bindClick("back", to: .named("mute"), in: device)
        #expect(config.string(["devices", Self.mouse, "buttons", "back"]) == "mute")
        // Same as Mouse Settings gives the click back and, with nothing else set, the whole binding.
        config.bindClick("forward", to: .standard, in: app)
        #expect(config[["apps"]] == nil)
    }

    @Test func noActionOnAMouseTurnsAnInheritedTriggerOffAndSameAsGivesItBack() throws {
        var config = try tree(#"{"buttons": {"forward": {"click": "navigateForward", "doubleClick": "missionControl"}}}"#)
        config.bindTrigger("forward", "doubleClick", to: .named("none"), in: device)
        #expect(config[["devices", Self.mouse, "buttons", "forward"]] as? NSDictionary == ["doubleClick": "none"])
        let onMouse = try #require(table(try decode(config).forDevice(Self.mouse).bindings[Self.forward]))
        #expect(onMouse.click == .navigateForward && onMouse.doubleClick == .none)
        // The row stays, reading No Action and "Set for this mouse.".
        let state = config.scopedButton("forward", in: device)
        #expect(state.children.map(\.name) == ["doubleClick"])
        #expect(state.doubleClick.own == .named("none") && state.doubleClick.effective.triggerLabel == "No Action")
        config.bindTrigger("forward", "doubleClick", to: .standard, in: device)
        #expect(config[["devices", Self.mouse, "buttons"]] == nil)
    }

    // An app's Double-click row inheriting a shortcut shows its glyphs but speaks it in words, as
    // the Click row does (#176 review).
    @Test func anInheritedShortcutOnAChildRowIsSpokenInWords() throws {
        let config = try tree(#"{"buttons": {"forward": {"click": "navigateForward", "doubleClick": {"keys": "cmd+w"}}}}"#)
        let child = config.scopedButton("forward", in: app).doubleClick
        #expect(child.inheritedLabel == "⌘W")
        #expect(child.inheritedSpokenLabel == "Command W")
        #expect(ButtonAction.named("none").triggerSpokenLabel == "No Action")
    }

    @Test func oneHoldFormReplacesTheOtherAndTheDefaultSetDoesNotFillItBack() throws {
        let file = try tree("{}")
        // The gesture button's default is Hold and Move; a hold replaces it.
        let held = saved(file) { $0.bindTrigger("gesture", "hold", to: .named("launchpad")) }
        let decoded = try #require(table(try decode(held).bindings[Self.gestureButton]))
        #expect(decoded.click == .missionControl && decoded.hold == .launchpad && !decoded.moves)
        // Hold and Move from the Hold row brings the directions back and removes the hold.
        let moved = saved(held) { $0.bindTrigger("gesture", "hold", to: .gesture) }
        let again = try #require(table(try decode(moved).bindings[Self.gestureButton]))
        #expect(again.hold == .none && again.up == .missionControl && again.right == .spaceRight)
        // No Action on Hold and Move leaves the click alone: the bare form, which replaces the default.
        let plain = saved(file) { $0.bindTrigger("gesture", "hold", to: .named("none")) }
        #expect(plain.string(["buttons", "gesture"]) == "missionControl")
        guard case .action(.missionControl)? = try decode(plain).bindings[Self.gestureButton] else {
            Issue.record("the gesture button clicks Mission Control and nothing else")
            return
        }
    }

    @Test func holdAndMoveOverAWiderHoldWritesTheDirectionsOnly() throws {
        var config = try tree(#"{"buttons": {"forward": {"click": "navigateForward", "hold": "missionControl"}}}"#)
        config.bindHoldAndMove("forward", in: app)
        #expect(config[["apps", Self.app, "buttons", "forward"]] as? NSDictionary ==
            ["up": "missionControl", "down": "appExpose", "left": "spaceLeft", "right": "spaceRight"])
        let inApp = try #require(table(try decode(config).settings(forApp: Self.app)?.bindings[Self.forward]))
        #expect(inApp.click == .navigateForward && inApp.hold == .none && inApp.moves)
        // Where it applies already, nothing more is written.
        let before = config.data()
        config.bindHoldAndMove("forward", in: app)
        #expect(config.data() == before)
    }

    @Test func aDirectionOnABareBindingMakesATableWhoseClickItIs() throws {
        var config = try tree(#"{"buttons": {"back": {"keys": "cmd+w"}}}"#)
        config.bind("back", direction: "up", to: .named("launchpad"))
        #expect(config[["buttons", "back"]] as? NSDictionary == ["click": ["keys": "cmd+w"], "up": "launchpad"])
        _ = try decode(config)
        config.bindTrigger("back", "hold", to: .named("mute"))
        #expect(config[["buttons", "back"]] as? NSDictionary == ["click": ["keys": "cmd+w"], "hold": "mute"])
        _ = try decode(config)
    }

    @Test func aTableRoundTripsThroughASettingsWriteAndUnknownKeysSurvive() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "triggers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            {"future": {"x": 1},
             "buttons": {"forward": {"click": "navigateForward", "doubleClick": "missionControl", "hold": "precisePointer"}},
             "devices": {"\(Self.mouse)": {"name": "MX", "later": true, "buttons": {"forward": {"hold": {"precisePointer": 400}}}}},
             "apps": {"\(Self.app)": {"note": "mine", "buttons": {"forward": {"doubleClick": "appExpose"}}}}}
            """.utf8).write(to: url)
        let file = ConfigFile(url: url)
        let loaded = try ConfigTree(data: Data(contentsOf: url)).layered()
        var edited = loaded
        edited.bindClick("forward", to: .named("mute"))
        edited.bindTrigger("forward", "doubleClick", to: .named("showDesktop"), in: device)
        edited.bindTrigger("forward", "hold", to: .named("none"), in: app)
        let written = try file.save(loaded.changes(to: edited)).tree
        #expect(written[["future"]] as? NSDictionary == ["x": 1])
        #expect(written[["devices", Self.mouse, "later"]] as? Bool == true)
        #expect(written.string(["apps", Self.app, "note"]) == "mine")
        #expect(written[["devices", Self.mouse, "buttons", "forward"]] as? NSDictionary ==
            ["hold": ["precisePointer": 400], "doubleClick": "showDesktop"])
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        let top = try #require(table(config.bindings[Self.forward]))
        #expect(top.click == .mute && top.doubleClick == .missionControl && top.hold == .precisePointer(dpi: nil))
        let mouse = try #require(table(config.forDevice(Self.mouse).bindings[Self.forward]))
        #expect(mouse.doubleClick == .showDesktop && mouse.hold == .precisePointer(dpi: 400))
        let inApp = try #require(table(config.forDevice(Self.mouse).settings(forApp: Self.app)?.bindings[Self.forward]))
        #expect(inApp.click == .mute && inApp.doubleClick == .appExpose && inApp.hold == .none)
    }

    // MARK: Rows

    @Test func aRowShowsItsChildrenOnlyOnceTheyDoSomethingOrAreSetHere() throws {
        let config = try tree("""
            {"buttons": {"back": "navigateBack", "forward": {"click": "navigateForward", "doubleClick": "missionControl", "hold": "precisePointer"}}}
            """)
        let back = config.scopedButton("back", in: .global)
        #expect(back.children.isEmpty && back.click == .named("navigateBack") && back.summary == nil)
        let forward = config.scopedButton("forward", in: .global)
        #expect(forward.click == .named("navigateForward"))
        #expect(forward.children.map(\.name) == ["doubleClick", "hold"])
        #expect(forward.summary == "Double-click: Mission Control. Hold: Precise Pointer.")
        // The gesture button reads its click; Hold and Move is its Hold row.
        let gesture = try tree("{}").layered().scopedButton("gesture", in: .global)
        #expect(gesture.click == .named("missionControl"))
        #expect(gesture.hold.effective == .gesture && gesture.directions.map(\.name) == Gesture.directions)
        #expect(gesture.summary == "Hold and Move: Mission Control, App Exposé, Spaces.")
        // On a mouse that leaves it alone, the click and children are All Mice's.
        let inherited = config.scopedButton("forward", in: device)
        #expect(inherited.click == .standard && inherited.clickInheritedLabel == "Forward")
        #expect(inherited.children.map(\.name) == ["doubleClick", "hold"])
    }

    @Test func preciseOnTheClickOwnsTheButton() throws {
        let config = try tree(#"{"buttons": {"top": "precisePointer", "back": {"precisePointer": 400}}}"#)
        #expect(config.scopedButton("top", in: .global).effectiveClick.isWhileHeld)
        #expect(config.binding("back") == .named("precisePointer"))
        #expect(!ButtonAction.named("dragLock").isWhileHeld)
        #expect(ActionCatalog.groups.first { $0.title == "Mouse" }?.names.contains("precisePointer") == true)
        #expect(ActionCatalog.caption(for: "precisePointer") == "Slows the pointer while you hold the button.")
        #expect(ActionCatalog.caption(for: "dragLock") == "Click to start dragging, click again to let go.")
        #expect(ActionCatalog.label(for: "dragLock") == "Drag Lock")
    }

    @Test func theCaptureFixturesDecode() throws {
        // scripts/fixtures, for the chair's captures, AX dump and measure-input.sh runs (docs/development.md).
        func fixture(_ name: String) throws -> Config {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "scripts/fixtures/\(name).json")
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        }
        let config = try fixture("buttons-triggers")
        let forward = try #require(table(config.bindings[Self.forward]))
        #expect(forward.doubleClick == .missionControl && forward.hold == .precisePointer(dpi: nil))
        #expect(config.holdMs == 350 && config.doubleClickMs == 500)
        #expect(config.warnings.isEmpty)
        // The same buttons with only their clicks, to measure against.
        let clickOnly = try fixture("buttons-click-only")
        #expect(table(clickOnly.bindings[Self.forward]) == nil && clickOnly.doubleClickMs == nil && clickOnly.warnings.isEmpty)
    }

    @Test func theDoubleClickCaptionSaysTheLiveInterval() throws {
        #expect(Triggers.doubleClickCaption(milliseconds: 500) == "Single clicks wait 0.5 s for a second click.")
        #expect(Triggers.doubleClickCaption(milliseconds: 350) == "Single clicks wait 0.35 s for a second click.")
        #expect(Triggers.doubleClickCaption(milliseconds: 1000) == "Single clicks wait 1 s for a second click.")
        #expect(try tree("{}").doubleClickMilliseconds(systemSeconds: 0.4) == 400)
        #expect(try tree("{}").doubleClickMilliseconds(systemSeconds: nil) == 500)
        #expect(try tree(#"{"doubleClickMs": 250}"#).doubleClickMilliseconds(systemSeconds: 0.4) == 250)
    }

    // MARK: Mouse Default click

    @Test func addingATriggerToAMouseDefaultButtonLeavesTheClickOutSoATapStaysTheMouses() throws {
        var config = try tree("{}")
        config.bindTrigger("top", "doubleClick", to: .named("missionControl"))
        #expect(config[["buttons", "top"]] as? NSDictionary == ["doubleClick": "missionControl"])
        let decoded = try #require(table(try decode(config).bindings[0x00C4]))
        #expect(decoded.clickIsUnset && decoded.doubleClick == .missionControl)
        // The row and picker still read Mouse Default, with Mouse Default on offer beside the trigger.
        let state = config.scopedButton("top", in: .global)
        #expect(state.click == .standard && state.click.label == "Mouse Default" && state.canLeaveClickToMouse)
        config.bindTrigger("top", "hold", to: .named("mute"))
        #expect(config[["buttons", "top"]] as? NSDictionary == ["doubleClick": "missionControl", "hold": "mute"])
        // Removing the last trigger leaves no entry for the button, not {}.
        config.bindTrigger("top", "hold", to: .named("none"))
        config.bindTrigger("top", "doubleClick", to: .named("none"))
        #expect(!config.contains(["buttons", "top"]))
        // Where the default set binds the button (Back), the empty table is written back as Mouse Default.
        var back = try tree(#"{"buttons": {"back": "default"}}"#)
        back.bindTrigger("back", "hold", to: .named("mute"))
        #expect(back[["buttons", "back"]] as? NSDictionary == ["hold": "mute"])
        back.bindTrigger("back", "hold", to: .named("none"))
        #expect(back.string(["buttons", "back"]) == "default")
    }

    @Test func holdAndMoveOnAMouseDefaultButtonAlsoLeavesTheClickOut() throws {
        var config = try tree("{}")
        config.bindHoldAndMove("top")
        #expect(config[["buttons", "top", "click"]] == nil && config[["buttons", "top", "up"]] as? String == "missionControl")
        #expect(config.scopedButton("top", in: .global).click == .standard)
        var mouse = try tree(#"{"devices": {"\#(Self.mouse)": {"name": "MX", "buttons": {"forward": "default"}}}}"#)
        mouse.bindHoldAndMove("forward", in: device)
        #expect(mouse[["devices", Self.mouse, "buttons", "forward", "click"]] == nil)
        #expect(mouse.scopedButton("forward", in: device).click == .mouseDefault)
    }

    @Test func onlyAnExplicitNoneWritesClickNone() throws {
        var config = try tree(#"{"buttons": {"back": {"doubleClick": "missionControl"}}}"#)
        config.bindClick("back", to: .named("none"))
        #expect(config[["buttons", "back"]] as? NSDictionary == ["click": "none", "doubleClick": "missionControl"])
        let state = config.scopedButton("back", in: .global)
        #expect(state.click == .named("none") && !state.clickLeftToMouse)
        // Mouse Default takes the key out again, rather than writing none.
        config.bindClick("back", to: .standard)
        #expect(config[["buttons", "back"]] as? NSDictionary == ["doubleClick": "missionControl"])
        config.bindClick("back", to: .named("mute"))
        config.bindClick("back", to: .mouseDefault)
        #expect(config[["buttons", "back"]] as? NSDictionary == ["doubleClick": "missionControl"])
    }

    @Test func aMouseOrAppTableWithNoClickReadsMouseDefaultAndKeepsItWhenItsLastTriggerGoes() throws {
        var config = try tree(#"{"buttons": {"back": "mute"}}"#)
        config.bind("back", to: .mouseDefault, in: device)
        config.bindTrigger("back", "doubleClick", to: .named("appExpose"), in: device)
        #expect(config[["devices", Self.mouse, "buttons", "back"]] as? NSDictionary == ["doubleClick": "appExpose"])
        let state = config.scopedButton("back", in: device)
        #expect(state.click == .mouseDefault && state.click.label == "Mouse Default")
        let kit = try #require(table(try decode(config).forDevice(Self.mouse).bindings[0x0053]))
        #expect(kit.clickIsUnset && kit.doubleClick == .appExpose)
        // Mouse Default over a bare wider action stays the mouse's own once the table is empty again.
        config.bindTrigger("back", "doubleClick", to: .standard, in: device)
        #expect(config.string(["devices", Self.mouse, "buttons", "back"]) == "default")
        // Where nothing wider binds it, no entry at all.
        var bare = try tree("{}")
        bare.bindTrigger("back", "hold", to: .named("mute"), in: app)
        #expect(bare[["apps", Self.app, "buttons", "back"]] as? NSDictionary == ["hold": "mute"])
        #expect(bare.appButton(Self.app, button: "back").click == .mouseDefault)
        bare.bindTrigger("back", "hold", to: .standard, in: app)
        #expect(!bare.hasApp(Self.app))
    }

    @Test func mouseDefaultOnAMouseTableTakesTheClickOutUnlessAWiderClickWouldShowThrough() throws {
        var config = try tree("{}")
        config.bindClick("back", to: .named("mute"), in: device)
        config.bindTrigger("back", "hold", to: .named("appExpose"), in: device)
        #expect(config[["devices", Self.mouse, "buttons", "back"]] as? NSDictionary == ["click": "mute", "hold": "appExpose"])
        config.bindClick("back", to: .mouseDefault, in: device)
        #expect(config[["devices", Self.mouse, "buttons", "back"]] as? NSDictionary == ["hold": "appExpose"])
        // A wider table that names a click would show through: the whole binding goes native instead.
        var wider = try tree(#"{"buttons": {"back": {"click": "mute", "hold": "missionControl"}}}"#)
        wider.bindTrigger("back", "doubleClick", to: .named("appExpose"), in: device)
        #expect(!wider.scopedButton("back", in: device).canLeaveClickToMouse)
        wider.bindClick("back", to: .mouseDefault, in: device)
        #expect(wider.string(["devices", Self.mouse, "buttons", "back"]) == "default")
    }

    @Test func aDirectionOnAMouseDefaultBareBindingMakesATableWithNoClick() throws {
        var config = try tree(#"{"devices": {"\#(Self.mouse)": {"name": "MX", "buttons": {"back": "default"}}}}"#)
        config.bind("back", direction: "up", to: .named("launchpad"), in: device)
        #expect(config[["devices", Self.mouse, "buttons", "back"]] as? NSDictionary == ["up": "launchpad"])
    }
}
