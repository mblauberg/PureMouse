import Foundation
import PureMouseKit
import Testing
@testable import PureMouseMenu

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func decoded(_ tree: ConfigTree) throws -> Config { try JSONDecoder().decode(Config.self, from: tree.data()) }

/// The menu's state in Kit's terms, to compare with what the daemon's decoder resolves.
private struct Resolved: Equatable {
    var left: Action?
    var right: Action?
    var step: Int
    var reversed = false
}

private func kit(_ action: ButtonAction) -> Action? {
    switch action {
    case .named(let name): Action.named[name]
    case .keys(let spec): Keystroke(spec).map(Action.keys)
    case .run(let command): .run(command)
    case .haptic(let name): HapticWaveform(rawValue: name).map(Action.haptic)
    default: nil
    }
}

private func resolved(_ state: ThumbWheelState) -> Resolved {
    Resolved(left: state.pair.flatMap { kit($0.left) }, right: state.pair.flatMap { kit($0.right) }, step: state.step,
             reversed: state.reversed)
}

private func resolved(_ wheel: Config.ThumbWheel) -> Resolved {
    switch wheel.mode {
    case .scroll: Resolved(left: nil, right: nil, step: wheel.step, reversed: wheel.reversed)
    case .actions(let left, let right): Resolved(left: left, right: right, step: wheel.step, reversed: wheel.reversed)
    }
}

// MARK: Suggestions

@Test func suggestionsMatchBundleIDsRegardlessOfCase() {
    #expect(AppSuggestion.forApp("com.google.Chrome")?.thumbWheel == "tabs")
    #expect(AppSuggestion.forApp("COM.APPLE.SAFARI")?.choice == .preset("tabs"))
    #expect(AppSuggestion.forApp("us.zoom.xos")?.thumbWheel == "volume")
    #expect(AppSuggestion.forApp("com.microsoft.teams2")?.thumbWheel == "volume")
    #expect(AppSuggestion.forApp("com.apple.Preview")?.choice == .preset("zoom"))
    #expect(AppSuggestion.forApp("com.microsoft.Excel")?.choice == .scroll)
    #expect(AppSuggestion.forApp("com.example.nothing") == nil)
}

@Test func everySuggestionIsAThumbWheelActionTheDaemonKnows() {
    for (id, suggestion) in AppSuggestion.table {
        #expect(id == id.lowercased())
        #expect(suggestion.thumbWheel == "scroll" || Config.ThumbWheel.presets[suggestion.thumbWheel] != nil)
    }
}

// MARK: Thumb wheel pop-up

@Test func thePopUpListsEveryPresetTheDaemonKnows() {
    #expect(Set(ThumbWheelChoice.presetOrder) == Set(Config.ThumbWheel.presets.keys))
    for name in ThumbWheelChoice.presetOrder { #expect(ThumbWheelState.preset(name) != nil) }
}

@Test func readingTheChoice() {
    #expect(ThumbWheelChoice.read(nil, inApp: false) == .scroll)
    #expect(ThumbWheelChoice.read(["inverted": true], inApp: false) == .scroll)
    #expect(ThumbWheelChoice.read(nil, inApp: true) == .inherit)
    #expect(ThumbWheelChoice.read(["step": 2], inApp: true) == .inherit)
    #expect(ThumbWheelChoice.read(["action": "scroll"], inApp: true) == .scroll)
    #expect(ThumbWheelChoice.read(["action": "volume"], inApp: false) == .preset("volume"))
    #expect(ThumbWheelChoice.read(["action": "volume", "step": 1], inApp: false) == .preset("volume"))
    // Set by hand: left or right, alone or over an action, is Custom.
    #expect(ThumbWheelChoice.read(["left": "mute"], inApp: false) == .custom)
    #expect(ThumbWheelChoice.read(["action": "tabs", "right": ["keys": "cmd+]"]], inApp: true) == .custom)
    #expect(ThumbWheelChoice.read(["action": "warp"], inApp: false) == .custom)
}

@Test func choosingAPresetWritesItsNameAndKeepsOtherKeys() throws {
    var config = try tree(#"{"thumbWheel": {"inverted": true, "left": "mute", "step": 9, "future": 1}}"#)
    config.chooseThumbWheel(.preset("tabs"), at: ["thumbWheel"])
    #expect(config[["thumbWheel"]] as? NSDictionary == ["inverted": true, "action": "tabs", "future": 1])
    config.chooseThumbWheel(.scroll, at: ["thumbWheel"])
    #expect(config[["thumbWheel"]] as? NSDictionary == ["inverted": true, "future": 1])
}

@Test func choosingScrollingWithNothingElseLeavesNoThumbWheelKey() throws {
    var config = try tree(#"{"thumbWheel": {"action": "zoom"}}"#)
    config.chooseThumbWheel(.scroll, at: ["thumbWheel"])
    #expect(config.root.isEmpty)
}

@Test func customKeepsWhatThePresetDid() throws {
    // Volume's own step is 2; a pair without an action defaults to 3, so the step is written.
    var config = try tree(#"{"thumbWheel": {"action": "volume"}}"#)
    let before = resolved(try decoded(config).thumbWheel!)
    config.chooseThumbWheel(.custom, at: ["thumbWheel"])
    #expect(config[["thumbWheel"]] as? NSDictionary == ["left": "volumeDown", "right": "volumeUp", "step": 2])
    #expect(resolved(try decoded(config).thumbWheel!) == before)
    #expect(config.thumbWheelChoice(at: ["thumbWheel"]) == .custom)

    // Tabs' step is the default, so none is written.
    var tabs = try tree(#"{"thumbWheel": {"action": "tabs"}}"#)
    tabs.chooseThumbWheel(.custom, at: ["thumbWheel"])
    #expect(tabs[["thumbWheel"]] as? NSDictionary == ["left": "previousTab", "right": "nextTab"])

    // From scrolling, both directions start as Do Nothing.
    var scroll = ConfigTree()
    scroll.chooseThumbWheel(.custom, at: ["thumbWheel"])
    #expect(scroll[["thumbWheel"]] as? NSDictionary == ["left": "none", "right": "none"])
}

@Test func choosingCustomAgainChangesNothing() throws {
    var config = try tree(#"{"thumbWheel": {"action": "zoom", "left": {"keys": "cmd+0"}}}"#)
    let before = config.data()
    config.chooseThumbWheel(.custom, at: ["thumbWheel"])
    #expect(config.data() == before)
}

@Test func settingADirectionWritesItsAction() throws {
    var config = try tree(#"{"thumbWheel": {"left": "none", "right": "none"}}"#)
    config.setThumbWheel("left", to: .keys("cmd+shift+["), at: ["thumbWheel"])
    config.setThumbWheel("right", to: .named("nextTab"), at: ["thumbWheel"])
    let wheel = config.thumbWheel(at: ["thumbWheel"])
    #expect(wheel.pair == .init(left: .keys("cmd+shift+["), right: .named("nextTab")))
    #expect(resolved(try decoded(config).thumbWheel!) == resolved(wheel))
}

@Test func thumbWheelStateMatchesTheDaemonsDecoder() throws {
    let globals = [
        #"{}"#, #"{"action": "scroll"}"#, #"{"action": "zoom"}"#, #"{"action": "volume", "step": 5}"#,
        #"{"left": "mute"}"#, #"{"action": "tabs", "right": {"keys": "cmd+]"}}"#, #"{"step": 7}"#,
        #"{"action": "spaces", "left": "none", "right": "showDesktop", "step": 1}"#,
        #"{"action": "tabs", "reversed": true}"#, #"{"inverted": true, "reversed": false}"#, #"{"reversed": true}"#,
    ]
    let apps = [
        #"{}"#, #"{"action": "scroll"}"#, #"{"action": "volume"}"#, #"{"right": "zoomIn"}"#,
        #"{"step": 12}"#, #"{"action": "tabs", "left": "mute"}"#, #"{"action": "spaces", "step": 2}"#,
        #"{"reversed": false}"#, #"{"action": "tabs", "reversed": true}"#,
    ]
    for global in globals {
        for app in apps {
            let json = #"{"thumbWheel": \#(global), "apps": {"x.y": {"thumbWheel": \#(app)}}}"#
            let config = try tree(json)
            let decoder = try decoded(config)
            let globalState = config.thumbWheel(at: ["thumbWheel"])
            #expect(resolved(globalState) == resolved(decoder.thumbWheel ?? Config.ThumbWheel()), "global \(global)")
            let appState = config.thumbWheel(at: ["apps", "x.y", "thumbWheel"], base: globalState)
            #expect(resolved(appState) == resolved(decoder.settings(forApp: "x.y")!.thumbWheel), "\(global) + app \(app)")
        }
    }
}

// MARK: Reverse direction

@Test func reversingGloballyWritesOnlyTrue() throws {
    var config = try tree(#"{"thumbWheel": {"inverted": true, "action": "tabs"}}"#)
    config.setThumbWheelReversed(true, at: ["thumbWheel"])
    #expect(config[["thumbWheel"]] as? NSDictionary == ["inverted": true, "action": "tabs", "reversed": true])
    #expect(config.thumbWheel(at: ["thumbWheel"]).reversed)
    #expect(try decoded(config).thumbWheel?.reversed == true)
    config.setThumbWheelReversed(false, at: ["thumbWheel"])
    #expect(config[["thumbWheel"]] as? NSDictionary == ["inverted": true, "action": "tabs"])
}

@Test func anAppsReverseIsSameAsEverywhereUntilSet() throws {
    var config = try tree(#"{"thumbWheel": {"action": "volume", "reversed": true}, "apps": {"a.b": {"thumbWheel": {"action": "tabs"}}}}"#)
    let path = ["apps", "a.b", "thumbWheel"]
    let base = config.thumbWheel(at: ["thumbWheel"])
    #expect(config.thumbWheelReversed(at: path) == nil && config.thumbWheel(at: path, base: base).reversed)
    // Normal in the app overrides the reversed global, so false is written.
    config.setThumbWheelReversed(false, at: path)
    #expect(config.thumbWheelReversed(at: path) == false)
    #expect(try decoded(config).settings(forApp: "a.b")?.thumbWheel.reversed == false)
    config.setThumbWheelReversed(nil, at: path)
    #expect(config[path] as? NSDictionary == ["action": "tabs"])
    // Choosing an action keeps the app's own direction.
    config.setThumbWheelReversed(true, at: path)
    config.chooseThumbWheel(.preset("zoom"), at: path, base: base)
    #expect(config.thumbWheelReversed(at: path) == true)
}

@Test func reversedRowsSetTheOtherKey() {
    #expect(ConfigTree.thumbWheelKey(turning: "left", reversed: false) == "left")
    #expect(ConfigTree.thumbWheelKey(turning: "left", reversed: true) == "right")
    #expect(ConfigTree.thumbWheelKey(turning: "right", reversed: true) == "left")
}

@Test func invertedMattersWhereSomeAppScrolls() throws {
    #expect(try !tree(#"{"thumbWheel": {"action": "tabs"}}"#).someAppScrollsThumbWheel)
    #expect(try !tree(#"{"thumbWheel": {"action": "tabs"}, "apps": {"a": {"thumbWheel": {"step": 2}}}}"#).someAppScrollsThumbWheel)
    #expect(try tree(#"{"thumbWheel": {"action": "tabs"}, "apps": {"a": {"thumbWheel": {"action": "scroll"}}}}"#).someAppScrollsThumbWheel)
    #expect(try tree(#"{"apps": {"a": {"buttons": {"back": "mute"}}}}"#).someAppScrollsThumbWheel)
}

// MARK: Thumb wheel per app

@Test func anAppsThumbWheelInheritsUntilChosen() throws {
    var config = try tree(#"{"thumbWheel": {"action": "volume"}, "apps": {"com.apple.Safari": {"buttons": {"back": "mute"}}}}"#)
    let path = ["apps", "com.apple.Safari", "thumbWheel"]
    let base = config.thumbWheel(at: ["thumbWheel"])
    #expect(config.thumbWheelChoice(at: path) == .inherit)
    config.chooseThumbWheel(.scroll, at: path, base: base)
    #expect(config.string(path + ["action"]) == "scroll")
    #expect(try decoded(config).settings(forApp: "com.apple.safari")?.thumbWheel.mode == .scroll)
    config.chooseThumbWheel(.inherit, at: path, base: base)
    #expect(!config.contains(path))
    #expect(config.string(["apps", "com.apple.Safari", "buttons", "back"]) == "mute")
}

@Test func customInAnAppKeepsItsStep() throws {
    // Zoom brings its own step (3); without an action the app's pair would take the global 5.
    var config = try tree(#"{"thumbWheel": {"action": "volume", "step": 5}}"#)
    let path = ["apps", "a.b", "thumbWheel"]
    let base = config.thumbWheel(at: ["thumbWheel"])
    config.chooseThumbWheel(.preset("zoom"), at: path, base: base)
    config.chooseThumbWheel(.custom, at: path, base: base)
    #expect(config[path] as? NSDictionary == ["left": "zoomOut", "right": "zoomIn", "step": 3])
    let wheel = try decoded(config).settings(forApp: "a.b")!.thumbWheel
    #expect(resolved(wheel) == Resolved(left: .zoomOut, right: .zoomIn, step: 3))
}

@Test func removingTheLastAppSettingRemovesTheApp() throws {
    var config = try tree(#"{"dpi": 1600, "apps": {"a.b": {"thumbWheel": {"action": "tabs"}}}}"#)
    config.chooseThumbWheel(.inherit, at: ["apps", "a.b", "thumbWheel"])
    #expect(config.root.keys.sorted() == ["dpi"])
}

// MARK: Apps

@Test func appKeysMatchRegardlessOfCase() throws {
    let config = try tree(#"{"apps": {"com.apple.safari": {}, "Com.Example.B": {}}}"#)
    #expect(config.appIDs == ["com.apple.safari", "Com.Example.B"])
    #expect(config.appKey("com.apple.Safari") == "com.apple.safari")
    #expect(config.hasApp("COM.APPLE.SAFARI"))
    #expect(config.appKey("org.new.App") == "org.new.App")
    #expect(!config.hasApp("org.new.App"))
}

@Test func bindingInAnAppAndBackToEverywhere() throws {
    var config = try tree(#"{"buttons": {"back": "navigateBack"}}"#)
    config.bindInApp("com.apple.Safari", button: "back", to: .named("previousTab"))
    #expect(config.string(["apps", "com.apple.Safari", "buttons", "back"]) == "previousTab")
    #expect(config.string(["buttons", "back"]) == "navigateBack")
    #expect(config.binding("back", in: ["apps", "com.apple.Safari"]) == .named("previousTab"))
    config.bindInApp("com.apple.Safari", button: "back", to: .standard)
    #expect(config.root.keys.sorted() == ["buttons"])
}

@Test func appEditsKeepUnknownKeys() throws {
    var config = try tree(#"{"apps": {"a.b": {"future": {"x": 1}, "smoothScroll": {"enabled": false}}}}"#)
    config.bindInApp("a.b", button: "top", to: .named("mute"))
    config.bindInApp("a.b", button: "top", to: .standard)
    config.setOverridesScrolling("a.b", true)
    config.setOverridesScrolling("a.b", false)
    #expect(config[["apps", "a.b"]] as? NSDictionary == ["future": ["x": 1], "smoothScroll": ["enabled": false]])
}

@Test func appBindingsUseAHexKeyAlreadyThere() throws {
    var config = try tree(#"{"apps": {"a.b": {"buttons": {"0x0053": "mute"}}}}"#)
    #expect(config.binding("back", in: ["apps", "a.b"]) == .named("mute"))
    config.bindInApp("a.b", button: "back", to: .named("zoomIn"))
    #expect(config[["apps", "a.b", "buttons"]] as? NSDictionary == ["0x0053": "zoomIn"])
}

@Test func anAppGestureStartsFromWhatTheButtonDid() throws {
    // Globally a gesture: the app's own starts from the global click.
    var config = try tree(#"{"buttons": {"gesture": {"click": "missionControl", "left": "spaceLeft"}}}"#)
    config.bindInApp("a.b", button: "gesture", to: .gesture)
    #expect(config[["apps", "a.b", "buttons", "gesture"]] as? NSDictionary == ["click": "missionControl"])
    // Its own action becomes the click.
    config.bindInApp("c.d", button: "back", to: .named("mute"))
    config.bindInApp("c.d", button: "back", to: .gesture)
    #expect(config[["apps", "c.d", "buttons", "back"]] as? NSDictionary == ["click": "mute"])
    // Globally a plain action.
    config.set("showDesktop", at: ["buttons", "top"])
    config.bindInApp("e.f", button: "top", to: .gesture)
    #expect(config[["apps", "e.f", "buttons", "top"]] as? NSDictionary == ["click": "showDesktop"])
    _ = try decoded(config)
}

@Test func anAppGestureDirectionFollowsTheGlobalOneUntilSet() throws {
    var config = try tree(#"{"buttons": {"gesture": {"click": "missionControl", "left": "spaceLeft"}}, "apps": {"a.b": {"buttons": {"gesture": {"click": "mute"}}}}}"#)
    config.bindInApp("a.b", button: "gesture", direction: "left", to: .named("none"))
    #expect(config.string(["apps", "a.b", "buttons", "gesture", "left"]) == "none")
    config.bindInApp("a.b", button: "gesture", direction: "left", to: .standard)
    #expect(!config.contains(["apps", "a.b", "buttons", "gesture", "left"]))
    // The last direction removes the app's binding: an empty object is not a gesture.
    config.bindInApp("a.b", button: "gesture", direction: "click", to: .standard)
    #expect(!config.contains(["apps"]))
}

@Test func scrollingOverrideStartsFromTheGlobalValues() throws {
    var config = try tree(#"{"smoothScroll": {"speed": 0.7}}"#)
    #expect(!config.overridesScrolling("a.b"))
    config.setOverridesScrolling("a.b", true)
    #expect(config[["apps", "a.b", "smoothScroll"]] as? NSDictionary == ["speed": 0.7, "smoothingMs": 125])
    #expect(config.overridesScrolling("a.b"))
    config.set(2.0, at: ["apps", "a.b", "smoothScroll", "speed"])
    config.setOverridesScrolling("a.b", true)  // already on: keeps the app's own values
    #expect(config.double(["apps", "a.b", "smoothScroll", "speed"]) == 2)
    config.setOverridesScrolling("a.b", false)
    #expect(config.root.keys.sorted() == ["smoothScroll"])
}

@Test func whetherAnAppScrollsSmoothly() throws {
    #expect(try tree(#"{"smoothScroll": {}}"#).scrollsSmoothly("a.b"))
    #expect(try !tree(#"{"smoothScroll": {"enabled": false}}"#).scrollsSmoothly("a.b"))
    #expect(try tree(#"{"smoothScroll": {"enabled": false}, "apps": {"a.b": {"smoothScroll": {"enabled": true}}}}"#).scrollsSmoothly("a.b"))
    // No smoothScroll anywhere: off, until the app has one of its own.
    #expect(try !tree(#"{}"#).scrollsSmoothly("a.b"))
    #expect(try tree(#"{"apps": {"a.b": {"smoothScroll": {"speed": 2}}}}"#).scrollsSmoothly("a.b"))
    let config = try tree(#"{"smoothScroll": {"enabled": false}, "apps": {"a.b": {"smoothScroll": {"speed": 2}}}}"#)
    #expect(!config.scrollsSmoothly("a.b"))
    #expect(try decoded(config).settings(forApp: "a.b")?.smoothScroll?.enabled == false)
}

@Test func removingAnAppRemovesItsWholeEntry() throws {
    var config = try tree(#"{"apps": {"com.apple.safari": {"future": 1, "buttons": {"back": "mute"}}, "c.d": {"thumbWheel": {"action": "zoom"}}}}"#)
    config.removeApp("com.apple.Safari")
    #expect(config.appIDs == ["c.d"])
    config.removeApp("c.d")
    #expect(config.root.isEmpty)
}

@Test func appSummaries() throws {
    let config = try tree(#"{"apps": {"a.b": {"thumbWheel": {"action": "tabs"}, "buttons": {"back": "mute", "top": "zoomIn"}, "smoothScroll": {"speed": 2}}, "c.d": {"buttons": {"back": "mute"}}}}"#)
    #expect(config.appSummary("a.b") == "Thumb wheel: Switch Tabs, 2 buttons, Scrolling speed")
    #expect(config.appSummary("c.d") == "1 button")
    #expect(config.appSummary("e.f") == "Same as Everywhere")
    // Direction alone is an override too.
    let directions = try tree(#"{"apps": {"a.b": {"thumbWheel": {"reversed": true}}, "c.d": {"thumbWheel": {"reversed": false}}, "e.f": {"thumbWheel": {"action": "tabs", "reversed": true}}}}"#)
    #expect(directions.appSummary("a.b") == "Thumb wheel: Reversed")
    #expect(directions.appSummary("c.d") == "Thumb wheel: Normal direction")
    #expect(directions.appSummary("e.f") == "Thumb wheel: Switch Tabs, reversed")
}

@Test func appEditsReplayOntoAHandEditedFile() throws {
    let loaded = try tree(#"{"apps": {"a.b": {"buttons": {"back": "mute"}}}}"#)
    var edited = loaded
    edited.chooseThumbWheel(.preset("volume"), at: ["apps", "a.b", "thumbWheel"])
    var onDisk = try tree(#"{"apps": {"a.b": {"buttons": {"back": "zoomIn"}}, "c.d": {"buttons": {"top": "mute"}}}}"#)
    onDisk.apply(loaded.changes(to: edited))
    #expect(onDisk.string(["apps", "a.b", "buttons", "back"]) == "zoomIn")
    #expect(onDisk.string(["apps", "c.d", "buttons", "top"]) == "mute")
    #expect(onDisk.string(["apps", "a.b", "thumbWheel", "action"]) == "volume")
}

// MARK: Actions

@Test func everyNamedActionIsInThePickerWithALabelAndSymbol() {
    let listed = ActionCatalog.groups.flatMap(\.names)
    #expect(Set(listed + ["none"]) == Set(Action.named.keys))
    for name in listed + ["none"] {
        #expect(ActionCatalog.label(for: name) != name)
        #expect(ActionCatalog.symbol(for: name) != nil)
    }
}

@Test func anAppPickerOffersSameAsEverywhereInsteadOfDefault() {
    let entries = PickerEntry.all(allowsDefault: false, allowsGesture: true, sameAsEverywhere: "Mission Control")
    #expect(entries.first?.label == "Same as Everywhere")
    #expect(entries.first?.detail == "(Mission Control)")
    #expect(entries.first?.matches(.standard) == true)
    #expect(!entries.contains { $0.id == "default" })
}

// MARK: Haptics

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

@Test func aThumbWheelDirectionCanPlayAHaptic() throws {
    var config = try tree(#"{"thumbWheel":{"action":"volume"}}"#)
    config.chooseThumbWheel(.custom, at: ["thumbWheel"])
    config.setThumbWheel("right", to: .haptic("knock"), at: ["thumbWheel"])
    let wheel = try #require(try decoded(config).thumbWheel)
    #expect(resolved(wheel).right == .haptic(.knock))
    #expect(resolved(config.thumbWheel(at: ["thumbWheel"])) == resolved(wheel))
}

@Test func anAppButtonCanPlayAHaptic() throws {
    var config = try tree("{}")
    config.bindInApp("com.apple.Safari", button: "top", to: .haptic("completed"))
    #expect(config.binding("top", in: ["apps", "com.apple.Safari"]) == .haptic("completed"))
    _ = try decoded(config)
}

// MARK: Thumb panel

@Test func theThumbPanelIsListedOnlyWhereItCanBeUsed() {
    let withoutPanel: Set<UInt16> = [0x52, 0x53, 0x56, 0xC3, 0xC4]
    #expect(!ButtonRows.named(deviceCIDs: nil, configKeys: []).contains(.thumbPanel))
    #expect(ButtonRows.named(deviceCIDs: nil, configKeys: []).count == 5)
    #expect(!ButtonRows.named(deviceCIDs: withoutPanel, configKeys: ["back"]).contains(.thumbPanel))
    #expect(ButtonRows.named(deviceCIDs: withoutPanel.union([0x1A0]), configKeys: []).contains(.thumbPanel))
    #expect(ButtonRows.named(deviceCIDs: withoutPanel, configKeys: ["thumbPanel"]).contains(.thumbPanel))
    #expect(ButtonRows.named(deviceCIDs: nil, configKeys: ["0x01A0"]).contains(.thumbPanel))
}

// MARK: Replaying app edits

@Test func aFirstAppSettingMergesIntoAppsAddedByHand() throws {
    let file = try tree("{}")
    var edited = file
    edited.bindInApp("a.b", button: "back", to: .named("previousTab"))
    let changes = file.changes(to: edited)
    #expect(changes.map(\.path) == [["apps", "a.b", "buttons", "back"]])
    var onDisk = try tree(#"{"apps": {"c.d": {"thumbWheel": {"action": "volume"}}}}"#)
    onDisk.apply(changes)
    #expect(onDisk.string(["apps", "a.b", "buttons", "back"]) == "previousTab")
    #expect(onDisk.string(["apps", "c.d", "thumbWheel", "action"]) == "volume")
}

@Test func aNewEmptyObjectIsStillSet() throws {
    let loaded = try tree("{}")
    var edited = loaded
    edited.set([String: Any](), at: ["smoothScroll"])
    var onDisk = try tree(#"{"dpi": 800}"#)
    onDisk.apply(loaded.changes(to: edited))
    #expect(onDisk.contains(["smoothScroll"]))
    #expect(onDisk.int(["dpi"]) == 800)
}

@Test func removingAnEmptyAppIsSaved() throws {
    let loaded = try tree(#"{"apps": {"a.b": {}, "c.d": {"buttons": {"back": "mute"}}}}"#)
    var edited = loaded
    edited.removeApp("a.b")
    let changes = loaded.changes(to: edited)
    #expect(!changes.isEmpty)
    var onDisk = loaded
    onDisk.apply(changes)
    #expect(!onDisk.hasApp("a.b"))
    #expect(onDisk.string(["apps", "c.d", "buttons", "back"]) == "mute")
}

@Test func removingAnUnsavedAppChangesNothing() throws {
    let loaded = try tree(#"{"apps": {}}"#)
    var edited = loaded
    // Added in the pane (nothing written), then removed.
    edited.removeApp("a.b")
    #expect(edited.contains(["apps"]))
    let changes = loaded.changes(to: edited)
    #expect(changes.isEmpty)
    var onDisk = try tree(#"{"apps": {"c.d": {"buttons": {"back": "mute"}}}}"#)
    onDisk.apply(changes)
    #expect(onDisk.string(["apps", "c.d", "buttons", "back"]) == "mute")
}

@Test func removingTheLastKeyRecordsOnlyThatKey() throws {
    let loaded = try tree(#"{"apps": {"a.b": {"buttons": {"back": "mute"}}}}"#)
    var edited = loaded
    edited.bindInApp("a.b", button: "back", to: .standard)
    #expect(!edited.contains(["apps"]))
    let changes = loaded.changes(to: edited)
    #expect(changes.map(\.path) == [["apps", "a.b", "buttons", "back"]])
    var onDisk = try tree(#"{"apps": {"a.b": {"buttons": {"back": "mute"}}, "c.d": {"thumbWheel": {"action": "zoom"}}}}"#)
    onDisk.apply(changes)
    #expect(!onDisk.hasApp("a.b"))
    #expect(onDisk.string(["apps", "c.d", "thumbWheel", "action"]) == "zoom")
}
