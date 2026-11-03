import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

private let mouse = "mb03400000000"
private let other = "p046d"

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func device(_ key: String) -> ConfigScope { ConfigScope.device(key)! }

/// The keys that differ between two trees, as `ConfigFile.save` would replay them.
private func changed(_ before: ConfigTree, _ after: ConfigTree) -> Set<String> {
    Set(before.changes(to: after).map { $0.path.joined(separator: ".") })
}

// MARK: Scopes

@Test func aDeviceScopeExistsOnlyForAKeyKitAccepts() {
    #expect(ConfigScope.device(mouse)?.prefix == ["devices", mouse])
    #expect(ConfigScope.device(other)?.prefix == ["devices", other])
    #expect(ConfigScope.device(mouse)?.deviceKey == mouse)
    for rejected in ["", "m", "mb034", "MB03400000000", "mb034000000000", "m000000000000", "mffffffffffff",
                     "p46d", "P046D", "p046d0", "x046d", "mb0340000000g", "devices"] {
        #expect(Config.isDeviceKey(rejected) == false)
        #expect(ConfigScope.device(rejected) == nil, "\(rejected)")
    }
    #expect(ConfigScope.global.prefix.isEmpty)
    #expect(ConfigScope.global.deviceKey == nil)
    #expect(ConfigScope.app("devices").deviceKey == nil)
    #expect(ConfigScope.app("com.apple.Safari").prefix == ["apps", "com.apple.Safari"])
}

@Test func deviceEntriesNameTheMiceKitWouldKeep() throws {
    let config = try tree(#"""
        {"devices": {"mb03400000000": {"name": "MX Master 3S", "dpi": 1200}, "p046d": {"dpi": 1000},
                     "MB03440910000": {"name": "Upper"}, "nope": {"name": "Skipped"}, "m000000000000": {"name": "Zeros"}}}
        """#)
    #expect(config.deviceEntries == [mouse: "MX Master 3S", other: "p046d", "mb03440910000": "Upper"])
    #expect(ConfigTree().deviceEntries.isEmpty)
}

// MARK: Writing

@Test func aValueSetInADeviceScopeChangesOnlyThatPathAndAddsTheNameOnce() throws {
    let before = try tree(#"{"dpi": 800, "buttons": {"back": "mute"}, "future": {"x": 1}}"#)
    var config = before
    let ok1 = config.set(1200, at: ["dpi"], in: device(mouse), name: "MX Master 3S")
    #expect(ok1)
    #expect(changed(before, config) == ["devices.\(mouse).dpi", "devices.\(mouse).name"])
    #expect(config.string(["devices", mouse, "name"]) == "MX Master 3S")
    #expect(config.int(["dpi"]) == 800)

    // The entry exists, so another value adds nothing else, and a different name is not written.
    let second = config
    config.set(true, at: ["scrollWheel", "inverted"], in: device(mouse), name: "Renamed")
    #expect(changed(second, config) == ["devices.\(mouse).scrollWheel.inverted"])
    #expect(config.string(["devices", mouse, "name"]) == "MX Master 3S")

    // Changing a value in place is one path.
    let third = config
    config.set(1600, at: ["dpi"], in: device(mouse))
    #expect(changed(third, config) == ["devices.\(mouse).dpi"])

    // Without a name the key stands in for it.
    var anonymous = ConfigTree()
    anonymous.set(1, at: ["dpi"], in: device(other))
    #expect(anonymous.string(["devices", other, "name"]) == other)
}

@Test func aDeviceWriteThatReplaysOntoAHandEditedFileKeepsTheEdit() throws {
    let loaded = try tree(#"{"dpi": 800}"#)
    var edited = loaded
    edited.set(1200, at: ["dpi"], in: device(mouse), name: "MX")
    var onDisk = try tree(#"{"dpi": 900, "devices": {"\#(mouse)": {"scrollWheel": {"mode": "ratchet"}}}}"#)
    onDisk.apply(loaded.changes(to: edited))
    #expect(onDisk.int(["dpi"]) == 900)
    #expect(onDisk.int(["devices", mouse, "dpi"]) == 1200)
    #expect(onDisk.string(["devices", mouse, "scrollWheel", "mode"]) == "ratchet")
}

@Test func onlyKitsDeviceSectionsAreWrittenUnderADevice() throws {
    let before = try tree(#"{"dpi": 800}"#)
    #expect(Config.deviceSections == ["dpi", "dpiPresets", "scrollWheel", "thumbWheel", "smoothScroll", "buttons", "gesture"])
    for refused in [["apps", "com.example.x", "buttons"], ["universalControl", "handOff"], ["notifications", "lowBattery"],
                    ["name"], ["devices"], ["future"], []] {
        var config = before
        let ok2 = config.set(1, at: refused, in: device(mouse))
        #expect(ok2 == false, "\(refused)")
        let ok3 = config.set(nil, at: refused, in: device(mouse))
        #expect(ok3 == false, "\(refused)")
        #expect(config.data() == before.data(), "\(refused)")
    }
    for section in Config.deviceSections.sorted() {
        var config = before
        let ok4 = config.set(1, at: [section, "x"], in: device(mouse))
        #expect(ok4)
        #expect(config.contains(["devices", mouse, section, "x"]))
    }
}

@Test func removingTheLastOverrideRemovesTheEntry() throws {
    var config = try tree(#"{"dpi": 800, "devices": {"\#(other)": {"dpi": 1000}}}"#)
    config.set(1200, at: ["dpi"], in: device(mouse), name: "MX")
    config.set("ratchet", at: ["scrollWheel", "mode"], in: device(mouse))
    config.set(nil, at: ["dpi"], in: device(mouse))
    #expect(config.string(["devices", mouse, "name"]) == "MX")
    config.set(nil, at: ["scrollWheel", "mode"], in: device(mouse))
    // A name-only entry is not kept.
    #expect(config.contains(["devices", mouse]) == false)
    #expect(config.int(["devices", other, "dpi"]) == 1000)

    config.set(nil, at: ["dpi"], in: device(other))
    #expect(config.contains(["devices"]) == false)
    #expect(config.int(["dpi"]) == 800)
}

@Test func anEntryWithAKeyTheAppDoesNotKnowIsKept() throws {
    var config = try tree(#"{"devices": {"\#(mouse)": {"name": "MX", "notes": "mine", "dpi": 1200}}}"#)
    config.set(nil, at: ["dpi"], in: device(mouse))
    #expect(config.string(["devices", mouse, "notes"]) == "mine")
    #expect(config.string(["devices", mouse, "name"]) == "MX")
}

@Test func removingWhatIsNotThereChangesNothingAndPrunesNothing() throws {
    // A hand-written name-only entry stays when a removal finds nothing to remove.
    let before = try tree(#"{"devices": {"\#(mouse)": {"name": "MX"}}}"#)
    var config = before
    let ok5 = config.set(nil, at: ["dpi"], in: device(mouse))
    #expect(ok5)
    #expect(config.data() == before.data())
    let ok6 = config.set(nil, at: ["buttons", "back"], in: device(other))
    #expect(ok6)
    #expect(config.data() == before.data())
}

@Test func theGlobalAndAppScopesWriteAsBefore() throws {
    var config = try tree(#"{"future": 1}"#)
    var plain = config
    config.set(5, at: ["scrollWheel", "smartShiftThreshold"], in: .global)
    plain.set(5, at: ["scrollWheel", "smartShiftThreshold"])
    #expect(config.data() == plain.data())
    config.set("mute", at: ["buttons", "back"], in: .app("com.example.x"))
    plain.set("mute", at: ["apps", "com.example.x", "buttons", "back"])
    #expect(config.data() == plain.data())
    #expect(config.contains(["devices"]) == false)
    // Apps keep what they did: the entry goes with its last key.
    config.set(nil, at: ["buttons", "back"], in: .app("com.example.x"))
    #expect(config.contains(["apps"]) == false)
}

@Test func buttonsBindInADeviceThroughTheSameRules() throws {
    var config = try tree(#"{"buttons": {"back": "mute", "gesture": {"click": "mute", "up": "missionControl"}}, "devices": {"\#(mouse)": {"buttons": {"0x0056": "appExpose"}}}}"#)
    // A hex spelling already in the entry is edited in place.
    config.bind("forward", to: .named("launchpad"), in: device(mouse))
    #expect(config.string(["devices", mouse, "buttons", "0x0056"]) == "launchpad")
    #expect(config.contains(["devices", mouse, "buttons", "forward"]) == false)
    #expect(config.binding("forward", in: device(mouse)) == .named("launchpad"))
    #expect(config.binding("back", in: device(mouse)) == .standard)
    #expect(config.binding("back") == .named("mute"))

    // A new gesture starts from what applied on that mouse, and writes only under the device.
    config.bind("back", to: .gesture, in: device(mouse))
    #expect(config.gestureBinding("back", "click", in: device(mouse)) == .named("mute"))
    config.bind("back", direction: "up", to: .named("appExpose"), in: device(mouse))
    #expect(config.gestureBinding("back", "up", in: device(mouse)) == .named("appExpose"))
    config.bind("back", to: .standard, in: device(mouse))
    config.bind("forward", to: .standard, in: device(mouse))
    #expect(config.contains(["devices"]) == false)
    #expect(config.binding("back") == .named("mute"))

    // The gesture the top level has is the one a device starts from, direction by direction.
    config.bind("gesture", direction: "down", to: .named("showDesktop"), in: device(mouse))
    #expect(config.resolved(["buttons", "gesture", "up"], in: device(mouse)) as? String == "missionControl")
    #expect(config.resolved(["buttons", "gesture", "down"], in: device(mouse)) as? String == "showDesktop")
    #expect(config.isOverridden(["buttons", "gesture", "down"], in: device(mouse)))
    #expect(config.isOverridden(["buttons", "gesture", "up"], in: device(mouse)) == false)
}

// MARK: Reading

@Test func resolvedFallsBackPerLeaf() throws {
    let config = try tree(#"""
        {"dpi": 800, "dpiPresets": [400, 800], "scrollWheel": {"inverted": true, "smartShiftThreshold": 20},
         "gesture": {"distanceMm": 6}, "apps": {"a.b": {"dpi": 1}},
         "buttons": {"0x0053": "mute", "forward": "appExpose",
                     "gesture": {"click": "mute", "up": "missionControl"}},
         "devices": {"\#(mouse)": {"dpiPresets": [1000], "scrollWheel": {"inverted": false},
                                  "buttons": {"back": "launchpad", "gesture": {"up": "showDesktop", "left": "mute"}}}}}
        """#)
    let d = device(mouse)
    #expect(config.resolved(["dpi"], in: d) as? Int == 800)
    #expect(config.resolved(["dpiPresets"], in: d) as? [Int] == [1000])
    #expect(config.resolved(["scrollWheel", "inverted"], in: d) as? Bool == false)
    #expect(config.resolved(["scrollWheel", "smartShiftThreshold"], in: d) as? Int == 20)
    let wheel = config.resolved(["scrollWheel"], in: d) as? [String: Any]
    #expect(wheel?["inverted"] as? Bool == false && wheel?["smartShiftThreshold"] as? Int == 20)
    #expect(config.resolved(["gesture", "distanceMm"], in: d) as? Int == 6)
    // A button is the device's over the top level's, whatever spells its control.
    #expect(config.resolved(["buttons", "back"], in: d) as? String == "launchpad")
    #expect(config.resolved(["buttons", "0x53"], in: d) as? String == "launchpad")
    #expect(config.resolved(["buttons", "forward"], in: d) as? String == "appExpose")
    #expect(config.resolved(["buttons", "gesture", "click"], in: d) as? String == "mute")
    #expect(config.resolved(["buttons", "gesture", "up"], in: d) as? String == "showDesktop")
    #expect(config.resolved(["buttons", "gesture", "left"], in: d) as? String == "mute")
    #expect(config.resolved(["buttons", "gesture", "down"], in: d) == nil)
    // Sections a device cannot set are the top level's.
    #expect(config.resolved(["apps", "a.b", "dpi"], in: d) as? Int == 1)
    // A mouse with no entry, and the top level, read the top level.
    #expect(config.resolved(["dpiPresets"], in: device(other)) as? [Int] == [400, 800])
    #expect(config.resolved(["dpiPresets"], in: .global) as? [Int] == [400, 800])
    // An app scope has nothing wider to fall back to here: its own.
    #expect(config.resolved(["dpi"], in: .app("a.b")) as? Int == 1)
    #expect(config.resolved(["dpiPresets"], in: .app("a.b")) == nil)
}

@Test func aPrimaryClickBindingIsNeverResolved() throws {
    let config = try tree(#"{"buttons": {"0x0050": "mute"}, "devices": {"\#(mouse)": {"buttons": {"0x51": "mute"}}}}"#)
    #expect(config.resolved(["buttons", "0x0050"], in: device(mouse)) == nil)
    #expect(config.resolved(["buttons", "0x51"], in: device(mouse)) == nil)
    #expect((config.resolved(["buttons"], in: device(mouse)) as? [String: Any])?.isEmpty == true)
}

@Test func isOverriddenMeansTheScopeSetsIt() throws {
    let config = try tree(#"""
        {"dpi": 800, "scrollWheel": {"inverted": true}, "apps": {"a.b": {"buttons": {"back": "mute"}}},
         "devices": {"\#(mouse)": {"dpi": 1200, "buttons": {"0x0053": "launchpad"}}}}
        """#)
    let d = device(mouse)
    #expect(config.isOverridden(["dpi"], in: d))
    #expect(config.isOverridden(["buttons", "back"], in: d))
    #expect(config.isOverridden(["buttons"], in: d))
    #expect(config.isOverridden(["buttons", "forward"], in: d) == false)
    #expect(config.isOverridden(["scrollWheel", "inverted"], in: d) == false)
    #expect(config.isOverridden(["scrollWheel"], in: d) == false)
    #expect(config.isOverridden(["dpi"], in: device(other)) == false)
    #expect(config.isOverridden(["dpi"], in: .global) == false)
    #expect(config.isOverridden(["apps", "a.b"], in: d) == false)
    #expect(config.isOverridden(["buttons", "back"], in: .app("a.b")))
}

@Test func unknownKeysAndOtherEntriesSurviveDeviceEdits() throws {
    var config = try tree(#"{"future": {"x": 1}, "devices": {"\#(other)": {"dpi": 1000, "extra": [1, 2]}, "weird": {"a": 1}}}"#)
    config.set(1200, at: ["dpi"], in: device(mouse), name: "MX")
    config.set(nil, at: ["dpi"], in: device(mouse))
    #expect(config.int(["future", "x"]) == 1)
    #expect(config.int(["devices", other, "dpi"]) == 1000)
    #expect(config.contains(["devices", other, "extra"]))
    #expect(config.int(["devices", "weird", "a"]) == 1)
    #expect(config.contains(["devices", mouse]) == false)
}

// MARK: The thumb wheel

@Test func theThumbWheelIsReadByLayeringBecauseActionResetsWhatPerKeyFallbackWouldKeep() throws {
    let json = #"""
        {"thumbWheel": {"left": "mute", "right": "volumeUp", "step": 5},
         "devices": {"\#(mouse)": {"thumbWheel": {"action": "zoom"}}}}
        """#
    let config = try tree(json)
    let kit = try JSONDecoder().decode(Config.self, from: config.data()).forDevice(mouse).thumbWheel
    #expect(kit?.mode == .actions(left: .zoomOut, right: .zoomIn))
    #expect(kit?.step == 3)
    // Per key, the device's `action` comes with the top level's left, right and step.
    let merged = config.resolved(["thumbWheel"], in: device(mouse)) as? [String: Any]
    #expect(merged?["left"] as? String == "mute" && merged?["step"] as? Int == 5)
    // Layered, as the decoder does it, the wheel is the zoom pair at its own step.
    let state = config.thumbWheel(in: device(mouse))
    #expect(state.pair == .init(left: .named("zoomOut"), right: .named("zoomIn")))
    #expect(state.step == 3)
    #expect(config.thumbWheel(in: .global).pair == .init(left: .named("mute"), right: .named("volumeUp")))
}

// MARK: Repairs, each checked against Kit

private func decode(_ config: ConfigTree) throws -> Config { try JSONDecoder().decode(Config.self, from: config.data()) }

/// The gesture Kit resolves for a control on a mouse (nil key: the top level).
private func kitGesture(_ config: ConfigTree, _ key: String?, cid: UInt16 = 0x00C3) throws -> Config.Binding.Gesture? {
    if case .gesture(let gesture)? = try decode(config).forDevice(key).bindings[cid] { return gesture }
    return nil
}

private let gestureTree = #"""
    {"buttons": {"gesture": {"click": "mute", "up": "missionControl"}},
     "devices": {"\#(mouse)": {"name": "MX", "buttons": {"gesture": {"up": "launchpad", "down": "showDesktop"}}}}}
    """#

@Test func doNothingOnADeviceDirectionIsWrittenAsGivenAndSameAsAllMiceRemovesTheKey() throws {
    // Do Nothing hides the top level's direction: Kit resolves it to none, not missionControl.
    var config = try tree(gestureTree)
    let before = config
    config.bind("gesture", direction: "up", to: .named("none"), in: device(mouse))
    #expect(config.string(["devices", mouse, "buttons", "gesture", "up"]) == "none")
    var gesture = try #require(try kitGesture(config, mouse))
    #expect(gesture.up == Action.none)
    #expect(gesture.down == Action.named["showDesktop"])
    #expect(gesture.click == Action.named["mute"])
    #expect(changed(before, config) == ["devices.\(mouse).buttons.gesture.up"])
    #expect(try kitGesture(config, nil)?.up == Action.named["missionControl"])

    // Same as All Mice removes the direction, so the top level's applies; others stay.
    config.bind("gesture", direction: "up", to: .standard, in: device(mouse))
    gesture = try #require(try kitGesture(config, mouse))
    #expect(gesture.up == Action.named["missionControl"])
    #expect(gesture.down == Action.named["showDesktop"])
    #expect(config.contains(["devices", mouse, "buttons", "gesture", "up"]) == false)

    // The last direction takes the whole binding, and the entry with it.
    var last = try tree(#"{"buttons": {"gesture": {"click": "mute", "up": "missionControl"}}, "devices": {"\#(mouse)": {"name": "MX", "buttons": {"gesture": {"up": "launchpad"}}}}}"#)
    last.bind("gesture", direction: "up", to: .standard, in: device(mouse))
    #expect(try kitGesture(last, mouse)?.up == Action.named["missionControl"])
    #expect(last.contains(["devices"]) == false)

    // The top level keeps its rule: Do Nothing removes the key, unless it is the last one.
    var global = try tree(#"{"buttons": {"gesture": {"click": "mute", "up": "missionControl"}}}"#)
    global.bind("gesture", direction: "up", to: .named("none"))
    #expect(global.contains(["buttons", "gesture", "up"]) == false)
    global.bind("gesture", direction: "click", to: .standard)
    #expect(global.string(["buttons", "gesture", "click"]) == "none")
}

@Test func anEntryKeySpelledInUpperCaseIsTheEntryForThatMouse() throws {
    let upper = "MB03400000000"
    var config = try tree(#"""
        {"dpi": 800, "thumbWheel": {"left": "mute", "right": "volumeUp", "step": 5}, "buttons": {"back": "mute"},
         "devices": {"\#(upper)": {"name": "MX", "dpi": 1600, "thumbWheel": {"action": "zoom"},
                                  "buttons": {"0x0056": "launchpad"}}}}
        """#)
    let d = device(mouse)
    let kit = try decode(config).forDevice(mouse)
    #expect(kit.dpi == 1600)
    #expect(config.resolvedInt(["dpi"], in: d) == 1600)
    #expect(config.isOverridden(["dpi"], in: d))
    #expect(config.isOverridden(["buttons", "forward"], in: d))
    #expect(config.isOverridden(["buttons", "back"], in: d) == false)
    #expect(config.resolved(["buttons", "forward"], in: d) as? String == "launchpad")
    #expect(config.binding("forward", in: d) == .named("launchpad"))
    #expect(config.thumbWheel(in: d).pair == .init(left: .named("zoomOut"), right: .named("zoomIn")))
    #expect(config.thumbWheel(in: d).step == 3)
    #expect(config.deviceEntries == [mouse: "MX"])

    // Writes edit that entry; no lowercase twin appears.
    config.set(2400, at: ["dpi"], in: d)
    config.bind("back", to: .named("nextTab"), in: d)
    config.bind("forward", to: .standard, in: d)
    config.set(true, at: ["scrollWheel", "inverted"], in: d, name: "Other")
    let devices = try #require(config[["devices"]] as? [String: Any])
    #expect(devices.keys.sorted() == [upper])
    #expect(config.int(["devices", upper, "dpi"]) == 2400)
    #expect(config.string(["devices", upper, "buttons", "back"]) == "nextTab")
    #expect(config.string(["devices", upper, "name"]) == "MX")
    #expect(try decode(config).forDevice(mouse).dpi == 2400)
    // Removing the overrides one by one ends with the entry gone.
    config.set(nil, at: ["dpi"], in: d)
    config.set(nil, at: ["thumbWheel", "action"], in: d)
    config.set(nil, at: ["buttons", "back"], in: d)
    config.set(nil, at: ["scrollWheel", "inverted"], in: d)
    #expect(config.contains(["devices"]) == false)
}

@Test func whenSeveralEntryKeysSpellOneMouseTheLastInSortedOrderIsTheEntry() throws {
    // Sorted: "MB…" < "Mb…" < "mb…", and a later spelling replaces the earlier one whole.
    var config = try tree(#"{"dpi": 800, "devices": {"MB03400000000": {"dpi": 100, "name": "A"}, "Mb03400000000": {"dpi": 200, "name": "B"}}}"#)
    let d = device(mouse)
    #expect(try decode(config).forDevice(mouse).dpi == 200)
    #expect(config.resolvedInt(["dpi"], in: d) == 200)
    #expect(config.deviceEntries == [mouse: "B"])
    config.set(500, at: ["dpi"], in: d)
    #expect(config.int(["devices", "Mb03400000000", "dpi"]) == 500)
    #expect(config.int(["devices", "MB03400000000", "dpi"]) == 100)
    #expect(try decode(config).forDevice(mouse).dpi == 500)

    // A lowercase twin sorts last and so is the one that applies.
    config = try tree(#"{"devices": {"mb03400000000": {"dpi": 300}, "MB03400000000": {"dpi": 100}}}"#)
    #expect(config.resolvedInt(["dpi"], in: d) == 300)
    #expect(try decode(config).forDevice(mouse).dpi == 300)
    // Upper case in a `p` key too.
    config = try tree(#"{"devices": {"P046D": {"dpi": 1000}}}"#)
    #expect(config.resolvedInt(["dpi"], in: device(other)) == 1000)
    #expect(config.isOverridden(["dpi"], in: device(other)))
}

@Test func aDeviceSmoothScrollIsKeptWhenEmptyBecauseEmptyMeansOn() throws {
    let before = try tree(#"{"devices": {"\#(mouse)": {"name": "MX", "smoothScroll": {"speed": 2}}}}"#)
    var config = before
    config.set(nil, at: ["smoothScroll", "speed"], in: device(mouse))
    #expect((config[["devices", mouse, "smoothScroll"]] as? [String: Any])?.isEmpty == true)
    let kit = try decode(config).forDevice(mouse)
    #expect(kit.smoothScroll?.enabled == true)
    #expect(config.resolved(["smoothScroll"], in: device(mouse)) != nil)
    // The entry stays with it, and a replay onto the loaded tree makes the same edit.
    #expect(config.contains(["devices", mouse]))
    #expect(changed(before, config) == ["devices.\(mouse).smoothScroll.speed"])
    var replay = before
    replay.apply(before.changes(to: config))
    #expect(replay.data() == config.data())
    #expect(try decode(replay).forDevice(mouse).smoothScroll?.enabled == true)

    // The same for the key that turns it off: removing it leaves `{}`, on.
    var off = try tree(#"{"smoothScroll": {}, "devices": {"\#(mouse)": {"smoothScroll": {"enabled": false}}}}"#)
    #expect(try decode(off).forDevice(mouse).smoothScroll?.enabled == false)
    let loaded = off
    off.set(nil, at: ["smoothScroll", "enabled"], in: device(mouse))
    #expect(try decode(off).forDevice(mouse).smoothScroll?.enabled == true)
    var replayed = loaded
    replayed.apply(loaded.changes(to: off))
    #expect(replayed.data() == off.data())

    // Removing the section itself removes it.
    off.set(nil, at: ["smoothScroll"], in: device(mouse))
    #expect(off.contains(["devices"]) == false)
}

@Test func aGestureDirectionIsOverriddenWhenTheMouseBindsTheControlToSomethingElse() throws {
    let config = try tree(#"""
        {"buttons": {"gesture": {"click": "mute", "up": "missionControl", "down": "showDesktop"},
                     "top": {"up": "mute"}, "back": {"up": "mute"}},
         "devices": {"\#(mouse)": {"buttons": {"gesture": "launchpad", "0x00c4": {"left": "mute"}, "back": {"keys": "cmd+c"}}}}}
        """#)
    let d = device(mouse)
    // A plain action replaces the gesture, so none of its directions is the top level's.
    #expect(try kitGesture(config, mouse) == nil)
    for direction in Gesture.directions {
        #expect(config.isOverridden(["buttons", "gesture", direction], in: d), "\(direction)")
        #expect(config.isOverridden(["buttons", "back", direction], in: d), "\(direction)")
    }
    // A gesture merges: only the directions it sets are the mouse's.
    #expect(config.isOverridden(["buttons", "top", "left"], in: d))
    #expect(config.isOverridden(["buttons", "top", "up"], in: d) == false)
    #expect(try kitGesture(config, mouse, cid: 0x00C4)?.up == Action.named["mute"])
    #expect(config.isOverridden(["buttons", "forward", "up"], in: d) == false)
}

@Test func nullValuesAreAbsentOnBothSidesAsKitReadsThem() throws {
    let config = try tree(#"""
        {"dpi": 800, "scrollWheel": {"inverted": true, "mode": null}, "thumbWheel": {"left": "mute", "step": 5},
         "buttons": {"gesture": {"click": "mute", "up": "missionControl", "down": null}, "back": "mute"},
         "devices": {"\#(mouse)": {"name": null, "dpi": null, "scrollWheel": {"inverted": null, "mode": "freespin"},
                                  "thumbWheel": {"left": null, "step": null}, "smoothScroll": null, "gesture": null,
                                  "buttons": {"gesture": {"up": null, "left": "mute"}}}}}
        """#)
    let d = device(mouse)
    let kit = try decode(config).forDevice(mouse)
    #expect(kit.dpi == 800)
    #expect(config.resolvedInt(["dpi"], in: d) == 800)
    #expect(kit.scrollWheel?.inverted == true)
    #expect(config.resolvedBool(["scrollWheel", "inverted"], in: d) == true)
    #expect(config.resolved(["scrollWheel", "mode"], in: d) as? String == "freespin")
    #expect(config.resolved(["smoothScroll"], in: d) == nil && kit.smoothScroll == nil)
    #expect(config.resolved(["gesture"], in: d) == nil)
    let wheel = config.thumbWheel(in: d)
    #expect(wheel.pair?.left == .named("mute") && wheel.step == 5)
    #expect(kit.thumbWheel?.step == 5)
    let gesture = try #require(try kitGesture(config, mouse))
    #expect(gesture.up == Action.named["missionControl"] && gesture.left == Action.named["mute"] && gesture.down == Action.none)
    #expect(config.resolved(["buttons", "gesture", "up"], in: d) as? String == "missionControl")
    #expect(config.resolved(["buttons", "gesture", "down"], in: d) == nil)
    #expect(config.deviceEntries == [mouse: mouse])
    // Nothing a null spells is the mouse's own.
    for path in [["dpi"], ["scrollWheel", "inverted"], ["smoothScroll"], ["gesture"], ["buttons", "gesture", "up"], ["thumbWheel", "step"]] {
        #expect(config.isOverridden(path, in: d) == false, "\(path)")
    }
    #expect(config.isOverridden(["scrollWheel", "mode"], in: d))
    #expect(config.isOverridden(["buttons", "gesture", "left"], in: d))
}

@Test func aGestureOfNullDirectionsIsAGestureThatDoesNothingNewAsInKit() throws {
    let config = try tree(#"{"buttons": {"back": "mute"}, "devices": {"\#(mouse)": {"buttons": {"back": {"up": null}}}}}"#)
    let gesture = try #require(try kitGesture(config, mouse, cid: 0x0053))
    #expect(gesture.up == Action.none && gesture.click == Action.none)
    let resolved = config.resolved(["buttons", "back"], in: device(mouse)) as? [String: Any]
    #expect(resolved?.keys.contains { Gesture.directions.contains($0) } == true)
    #expect(ButtonAction(json: resolved) == .gesture)
}

@Test func anEntryThatKeepsOtherKeysKeepsItsNameWhenTheLastOverrideGoes() throws {
    let before = try tree(#"{"devices": {"\#(mouse)": {"name": "MX", "notes": "mine", "dpi": 1200}}}"#)
    var config = before
    config.set(nil, at: ["dpi"], in: device(mouse))
    #expect(config.string(["devices", mouse, "name"]) == "MX")
    #expect(config.string(["devices", mouse, "notes"]) == "mine")

    // The replay of an entry that went onto a file that has since gained a key keeps the name too.
    var written = try tree(#"{"dpi": 800}"#)
    written.set(1200, at: ["dpi"], in: device(mouse), name: "MX")
    let loaded = written
    written.set(nil, at: ["dpi"], in: device(mouse))
    #expect(written.contains(["devices"]) == false)
    var onDisk = loaded
    onDisk.set("mine", at: ["devices", mouse, "notes"])
    onDisk.apply(loaded.changes(to: written))
    #expect(onDisk.string(["devices", mouse, "name"]) == "MX")
    #expect(onDisk.string(["devices", mouse, "notes"]) == "mine")
    #expect(onDisk.contains(["devices", mouse, "dpi"]) == false)
    // With nothing else in it, the replay removes the entry as the direct edit did.
    var plain = loaded
    plain.apply(loaded.changes(to: written))
    #expect(plain.data() == written.data())
}

@Test func aDeviceGestureSummaryIsWhatAppliesOnThatMouse() throws {
    let config = try tree(gestureTree)
    #expect(config.gestureSummary("gesture") == "Click: Mute, 1 direction set.")
    // click from the top level, up and down from the mouse.
    #expect(config.gestureSummary("gesture", in: device(mouse)) == "Click: Mute, 2 directions set.")
    #expect(config.gestureSummary("gesture", in: device(other)) == "Click: Mute, 1 direction set.")
    var quiet = config
    quiet.bind("gesture", direction: "down", to: .named("none"), in: device(mouse))
    #expect(quiet.gestureSummary("gesture", in: device(mouse)) == "Click: Mute, 1 direction set.")
}

@Test func startingAGestureOnAMouseWritesNoClickTheTopLevelAlreadySupplies() throws {
    var config = try tree(#"{"buttons": {"gesture": {"click": "mute", "up": "missionControl"}, "back": "mute", "top": {"left": "mute"}}}"#)
    let before = config
    config.bind("gesture", to: .gesture, in: device(mouse))
    config.bind("top", to: .gesture, in: device(mouse))
    #expect(config.data() == before.data())
    #expect(try kitGesture(config, mouse)?.click == Action.named["mute"])
    // A control that is not a gesture at the top level starts one from what applied.
    config.bind("back", to: .gesture, in: device(mouse))
    #expect(config.resolved(["buttons", "back", "click"], in: device(mouse)) as? String == "mute")
    #expect(try kitGesture(config, mouse, cid: 0x0053)?.click == Action.named["mute"])
    // A mouse that binds the control to something else turns that into the gesture's click.
    var own = try tree(#"{"buttons": {"gesture": {"click": "mute"}}, "devices": {"\#(mouse)": {"buttons": {"gesture": "launchpad"}}}}"#)
    own.bind("gesture", to: .gesture, in: device(mouse))
    #expect(try kitGesture(own, mouse)?.click == Action.named["launchpad"])
}

@Test func typedResolvedReadersTellBoolsFromNumbers() throws {
    let config = try tree(#"""
        {"dpi": 800, "scrollWheel": {"inverted": true}, "smoothScroll": {"speed": 1.5, "enabled": true},
         "devices": {"\#(mouse)": {"dpi": 1600, "smoothScroll": {"speed": 2.5}, "scrollWheel": {"smartShiftThreshold": 1}}}}
        """#)
    let d = device(mouse)
    #expect(config.resolvedInt(["dpi"], in: d) == 1600)
    #expect(config.resolvedInt(["dpi"], in: device(other)) == 800)
    #expect(config.resolvedDouble(["smoothScroll", "speed"], in: d) == 2.5)
    #expect(config.resolvedBool(["smoothScroll", "enabled"], in: d) == true)
    #expect(config.resolvedBool(["scrollWheel", "inverted"], in: d) == true)
    // A bool is not a number, and a number is not a bool.
    #expect(config.resolvedInt(["scrollWheel", "inverted"], in: d) == nil)
    #expect(config.resolvedDouble(["smoothScroll", "enabled"], in: d) == nil)
    #expect(config.resolvedBool(["scrollWheel", "smartShiftThreshold"], in: d) == nil)
    #expect(config.resolvedBool(["dpi"], in: d) == nil)
    #expect(config.resolvedInt(["scrollWheel", "mode"], in: d) == nil)
    #expect(config.resolvedInt(["dpi"], in: .global) == 800)
}

// MARK: Parity with Kit's decoder

/// SplitMix64: the same trees on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct TreeMaker {
    var rng: SeededGenerator

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...items.count - 1)] }
    mutating func subset(_ keys: [String]) -> [String] { keys.filter { _ in chance(0.5) } }

    static let namedActions = ["none", "missionControl", "appExpose", "showDesktop", "launchpad", "spaceLeft", "spaceRight",
                               "navigateBack", "navigateForward", "volumeUp", "volumeDown", "mute", "nextTab", "previousTab",
                               "zoomIn", "zoomOut"]
    /// The control IDs the generator binds, each with every spelling the daemon accepts.
    static let spellings: [[String]] = [
        ["back", "0x0053", "53"], ["forward", "0x0056", "0x56"], ["top", "0x00c4", "0xC4"], ["gesture", "0x00c3"],
        ["middle", "0x0052"], ["thumbPanel", "0x01a0"], ["0x00fd"], ["0x0050", "0x51"],
    ]
    static let unknownNames = ["zz", "not a button"]

    mutating func action() -> Any {
        switch int(0...9) {
        case 0: return ["keys": pick(["cmd+c", "ctrl+shift+4", "cmd+]"])]
        case 1: return ["run": "open -a \(pick(["Safari", "Notes"]))"]
        case 2: return ["haptic": pick(HapticWaveform.allCases).rawValue]
        default: return pick(Self.namedActions)
        }
    }

    /// A gesture, or a plain action. A direction may be `null`, which Kit reads as absent, and a
    /// gesture of nothing but nulls is still a gesture.
    mutating func binding() -> Any {
        guard chance(0.35) else { return action() }
        var gesture: [String: Any] = [:]
        for direction in Gesture.directions {
            if chance(0.5) { gesture[direction] = action() } else if chance(0.12) { gesture[direction] = NSNull() }
        }
        return gesture.isEmpty ? ["click": action()] : gesture
    }

    mutating func buttons() -> [String: Any] {
        var out: [String: Any] = [:]
        for spellings in Self.spellings where chance(0.4) {
            for name in spellings where out.isEmpty || chance(0.7) || name == spellings[0] {
                // "default" (Mouse Default) is a value Kit reads in any of the sections.
                if chance(0.8) { out[name] = chance(0.15) ? "default" : binding() }
            }
        }
        for name in Self.unknownNames where chance(0.15) { out[name] = chance(0.2) ? "default" : action() }
        return out
    }

    /// `null` for a key that is not set, now and then.
    mutating func nulls(_ object: inout [String: Any], _ keys: [String]) {
        for key in keys where object[key] == nil && chance(0.1) { object[key] = NSNull() }
    }

    mutating func scope() -> [String: Any] {
        var out: [String: Any] = [:]
        if chance(0.5) { out["dpi"] = int(50...25600) }
        if chance(0.4) { out["dpiPresets"] = (0..<int(0...8)).map { _ in int(50...25600) } }
        if chance(0.6) {
            var wheel: [String: Any] = [:]
            if chance(0.5) { wheel["inverted"] = chance(0.5) }
            if chance(0.5) { wheel["mode"] = pick(["ratchet", "freespin"]) }
            if chance(0.5) { wheel["smartShiftThreshold"] = int(1...255) }
            nulls(&wheel, ["inverted", "mode", "smartShiftThreshold"])
            out["scrollWheel"] = wheel
        }
        if chance(0.6) {
            var thumb: [String: Any] = [:]
            if chance(0.4) { thumb["inverted"] = chance(0.5) }
            if chance(0.4) { thumb["reversed"] = chance(0.5) }
            if chance(0.5) { thumb["action"] = pick(["scroll", "zoom", "volume", "tabs", "spaces"]) }
            if chance(0.3) { thumb["left"] = action() }
            if chance(0.3) { thumb["right"] = action() }
            if chance(0.4) { thumb["step"] = int(1...36) }
            nulls(&thumb, ["inverted", "reversed", "action", "left", "right", "step"])
            out["thumbWheel"] = thumb
        }
        if chance(0.5) {
            var smooth: [String: Any] = [:]
            if chance(0.4) { smooth["enabled"] = chance(0.5) }
            if chance(0.4) { smooth["speed"] = Double(int(1...100)) / 10 }
            if chance(0.4) { smooth["horizontalSpeed"] = Double(int(1...100)) / 10 }
            if chance(0.4) { smooth["acceleration"] = Double(int(0...100)) / 10 }
            if chance(0.4) { smooth["smoothingMs"] = Double(int(0...2000)) }
            if chance(0.4) { smooth["shiftScrollsHorizontally"] = chance(0.5) }
            nulls(&smooth, ["enabled", "speed", "horizontalSpeed", "acceleration", "smoothingMs", "shiftScrollsHorizontally"])
            out["smoothScroll"] = smooth
        }
        if chance(0.7) { out["buttons"] = buttons() }
        if chance(0.5) {
            var gesture: [String: Any] = [:]
            if chance(0.6) { gesture["distanceMm"] = Double(int(5...500)) / 10 }
            if chance(0.6) { gesture["repeatIntervalMs"] = int(0...5000) }
            nulls(&gesture, ["distanceMm", "repeatIntervalMs"])
            out["gesture"] = gesture
        }
        for section in ["dpi", "scrollWheel", "thumbWheel", "smoothScroll", "buttons", "gesture"]
        where out[section] == nil && chance(0.08) {
            out[section] = NSNull()
        }
        return out
    }

    /// A key as `Config.deviceKey` gives it: lowercase.
    mutating func deviceKey() -> String {
        if chance(0.3) { return "p" + String(format: "%04x", int(1...0xFFFE)) }
        return "m" + (0..<6).map { _ in String(format: "%02x", int(1...0xFE)) }.joined()
    }

    /// A key as a file may spell it: as given, upper case, or a mix.
    mutating func spelled(_ key: String) -> String {
        switch int(0...3) {
        case 0: key.uppercased()
        case 1: String(key.map { chance(0.5) ? Character($0.uppercased()) : $0 })
        default: key
        }
    }

    /// A tree, and the lowercase keys of the mice its `devices` names. A mouse may be spelled by
    /// more than one entry key, and the last in sorted order applies.
    mutating func tree() -> (tree: ConfigTree, keys: [String]) {
        var root = scope()
        var devices: [String: Any] = [:]
        var keys: Set<String> = []
        for _ in 0..<int(1...3) {
            let key = deviceKey()
            keys.insert(key)
            for _ in 0..<(chance(0.3) ? 2 : 1) {
                var entry = scope()
                if chance(0.5) { entry["name"] = "Mouse \(int(1...99))" } else if chance(0.05) { entry["name"] = NSNull() }
                devices[spelled(key)] = entry
            }
        }
        root["devices"] = devices
        return (ConfigTree(root), keys.sorted())
    }
}

private func describe(_ binding: Config.Binding?) -> String {
    switch binding {
    case nil: "nil"
    case .action(let action)?: "action \(action)"
    case .gesture(let g)?: "gesture \(g.click) \(g.up) \(g.down) \(g.left) \(g.right)"
    }
}

private func decodeBinding(_ json: Any?) throws -> Config.Binding? {
    guard let json else { return nil }
    let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
    return try JSONDecoder().decode(Config.Binding.self, from: data)
}

private func kitAction(_ action: ButtonAction) -> Action? {
    switch action {
    case .named(let name): Action.named[name]
    case .keys(let spec): Keystroke(spec).map(Action.keys)
    case .run(let command): .run(command)
    case .haptic(let name): HapticWaveform(rawValue: name).map(Action.haptic)
    default: nil
    }
}

/// Everything Kit resolves for one config, as text: two configs resolve alike when these match.
private func fingerprint(_ kit: Config) -> String {
    let wheel = kit.scrollWheel.map { "\($0.inverted as Any) \($0.mode as Any) \($0.smartShiftThreshold as Any)" }
    let thumb = kit.thumbWheel.map { "\($0.inverted as Any) \($0.reversed) \($0.mode) \($0.step)" }
    let smooth = kit.smoothScroll.map {
        "\($0.enabled) \($0.speed) \($0.horizontalSpeed) \($0.acceleration) \($0.smoothingMs) \($0.shiftScrollsHorizontally)"
    }
    return [
        "dpi \(kit.dpi as Any)", "presets \(kit.dpiPresets)", "wheel \(wheel as Any)", "thumb \(thumb as Any)",
        "smooth \(smooth as Any)", "gesture \(kit.gesture.distanceMm) \(kit.gesture.repeatIntervalMs)",
        kit.buttons.keys.sorted().map { "button \($0) \(describe(kit.buttons[$0]))" }.joined(separator: "\n"),
        kit.bindings.keys.sorted().map { "binding \($0) \(describe(kit.bindings[$0]))" }.joined(separator: "\n"),
    ].joined(separator: "\n")
}

/// Whether `config` reads on `key` the way Kit resolves it, counting the controls whose gesture
/// merged. Every comparison is against `decoded.forDevice(key)`.
private func expectResolvedMatchesKit(_ config: ConfigTree, _ key: String, _ decoded: Config, _ note: Comment) throws -> Int {
    let scope = device(key)
    let kit = decoded.forDevice(key)
    var gesturesMerged = 0

    // Scalars replace, and the preset list replaces whole.
    #expect(config.resolved(["dpi"], in: scope) as? Int == kit.dpi, note)
    #expect(config.resolvedInt(["dpi"], in: scope) == kit.dpi, note)
    #expect((config.resolved(["dpiPresets"], in: scope) as? [Int] ?? []) == kit.dpiPresets, note)

    // scrollWheel, per key.
    let wheel = kit.scrollWheel
    #expect(config.resolved(["scrollWheel", "inverted"], in: scope) as? Bool == wheel?.inverted, note)
    #expect(config.resolvedBool(["scrollWheel", "inverted"], in: scope) == wheel?.inverted, note)
    #expect(config.resolved(["scrollWheel", "mode"], in: scope) as? String == wheel?.mode?.rawValue, note)
    #expect(config.resolvedInt(["scrollWheel", "smartShiftThreshold"], in: scope) == wheel?.smartShiftThreshold.map(Int.init), note)
    #expect((config.resolved(["scrollWheel"], in: scope) != nil) == (wheel != nil), note)

    // thumbWheel: `inverted` per key; the rest layered, since `action` resets the step.
    #expect(config.resolvedBool(["thumbWheel", "inverted"], in: scope) == kit.thumbWheel?.inverted, note)
    let thumb = config.thumbWheel(in: scope)
    let expected = kit.thumbWheel ?? Config.ThumbWheel()
    #expect(thumb.step == expected.step, note)
    #expect(thumb.reversed == expected.reversed, note)
    switch expected.mode {
    case .scroll:
        #expect(thumb.pair == nil, note)
    case .actions(let left, let right):
        #expect(thumb.pair.flatMap { kitAction($0.left) } == left, note)
        #expect(thumb.pair.flatMap { kitAction($0.right) } == right, note)
    }

    // smoothScroll, per key, with the decoder's defaults.
    let smooth = kit.smoothScroll
    #expect((config.resolved(["smoothScroll"], in: scope) != nil) == (smooth != nil), note)
    let fallback = Config.SmoothScroll()
    if let smooth {
        #expect((config.resolvedBool(["smoothScroll", "enabled"], in: scope) ?? fallback.enabled) == smooth.enabled, note)
        #expect((config.resolvedDouble(["smoothScroll", "speed"], in: scope) ?? fallback.speed) == smooth.speed, note)
        #expect((config.resolvedDouble(["smoothScroll", "horizontalSpeed"], in: scope) ?? fallback.horizontalSpeed) == smooth.horizontalSpeed, note)
        #expect((config.resolvedDouble(["smoothScroll", "acceleration"], in: scope) ?? fallback.acceleration) == smooth.acceleration, note)
        #expect((config.resolvedDouble(["smoothScroll", "smoothingMs"], in: scope) ?? fallback.smoothingMs) == smooth.smoothingMs, note)
        #expect((config.resolvedBool(["smoothScroll", "shiftScrollsHorizontally"], in: scope)
                 ?? fallback.shiftScrollsHorizontally) == smooth.shiftScrollsHorizontally, note)
    }

    // gesture, per key.
    let gestureDefaults = Config.GestureSettings()
    #expect((config.resolvedDouble(["gesture", "distanceMm"], in: scope) ?? gestureDefaults.distanceMm) == kit.gesture.distanceMm, note)
    #expect((config.resolvedInt(["gesture", "repeatIntervalMs"], in: scope) ?? gestureDefaults.repeatIntervalMs) == kit.gesture.repeatIntervalMs, note)

    // buttons: per control, whichever way it is spelled, and per direction in a gesture.
    for spellings in TreeMaker.spellings {
        let cid = try #require(NamedButton.cid(forKey: spellings[0]))
        for name in spellings {
            let binding = try decodeBinding(config.resolved(["buttons", name], in: scope))
            #expect(describe(binding) == describe(kit.bindings[cid]), "\(name) \(note.rawValue)")
        }
        let name = spellings[0]
        if case .gesture(let gesture)? = kit.bindings[cid] {
            gesturesMerged += 1
            let directions = ["click": gesture.click, "up": gesture.up, "down": gesture.down,
                              "left": gesture.left, "right": gesture.right]
            for (direction, action) in directions {
                let json = config.resolved(["buttons", name, direction], in: scope)
                let resolved = try json.map { try JSONDecoder().decode(Action.self, from: JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])) }
                #expect((resolved ?? Action.none) == action, "\(name).\(direction) \(note.rawValue)")
            }
        } else if kit.bindings[cid] != nil {
            #expect(config.resolved(["buttons", name, "up"], in: scope) == nil, note)
        }
    }
    // A name Kit has no control for is the mouse's binding, else the top level's, value and all.
    for name in TreeMaker.unknownNames {
        let binding = try decodeBinding(config.resolved(["buttons", name], in: scope))
        #expect(describe(binding) == describe(kit.buttons[name]), "\(name) \(note.rawValue)")
    }
    let all = config.resolved(["buttons"], in: scope) as? [String: Any] ?? [:]
    var named = Set<UInt16>()
    for (name, json) in all {
        guard let cid = NamedButton.cid(forKey: name) else { continue }
        named.insert(cid)
        #expect(describe(try decodeBinding(json)) == describe(kit.bindings[cid]), "\(name) \(note.rawValue)")
    }
    #expect(named == Set(kit.bindings.keys), note)
    #expect(Set(all.keys.filter { NamedButton.cid(forKey: $0) == nil }) == Set(kit.buttons.keys.filter { Config.Button.cid(for: $0) == nil }), note)
    for name in all.keys where NamedButton.cid(forKey: name) == nil {
        #expect(describe(try decodeBinding(all[name])) == describe(kit.buttons[name]), "\(name) \(note.rawValue)")
    }
    return gesturesMerged
}

@Test func resolvedAgreesWithKitsDeviceConfigOnGeneratedTrees() throws {
    var maker = TreeMaker(rng: SeededGenerator(state: 0x5075_7265_4D6F_7573))
    var devicesChecked = 0
    var gesturesMerged = 0
    var cased = 0
    var nulls = 0
    var defaults = 0
    for round in 0..<400 {
        let (config, keys) = maker.tree()
        let note = Comment(rawValue: "round \(round): \(String(decoding: config.data(), as: UTF8.self))")
        let decoded = try decode(config)
        let raw = (config[["devices"]] as? [String: Any]) ?? [:]
        cased += raw.keys.filter { $0 != $0.lowercased() }.count
        nulls += String(decoding: config.data(), as: UTF8.self).components(separatedBy: "null").count - 1
        defaults += String(decoding: config.data(), as: UTF8.self).components(separatedBy: "\"default\"").count - 1
        for key in keys {
            devicesChecked += 1
            gesturesMerged += try expectResolvedMatchesKit(config, key, decoded, note)
        }
    }
    // The generator reaches the interesting cases.
    #expect(devicesChecked > 400)
    #expect(gesturesMerged > 100)
    #expect(cased > 100)
    #expect(nulls > 400)
    #expect(defaults > 100)
}

// MARK: isOverridden against a definition taken from Kit

/// The leaf settings `isOverridden` is checked on, each with two values Kit accepts that the
/// generator never writes together.
nonisolated(unsafe) private let leafSentinels: [[String]: [Any]] = [
    ["dpi"]: [1234, 1235],
    ["dpiPresets"]: [[1234], [1235]],
    ["scrollWheel", "inverted"]: [true, false],
    ["scrollWheel", "mode"]: ["ratchet", "freespin"],
    ["scrollWheel", "smartShiftThreshold"]: [77, 78],
    ["thumbWheel", "inverted"]: [true, false],
    ["thumbWheel", "reversed"]: [true, false],
    ["smoothScroll", "enabled"]: [true, false],
    ["smoothScroll", "speed"]: [7.7, 7.6],
    ["smoothScroll", "shiftScrollsHorizontally"]: [true, false],
    ["gesture", "distanceMm"]: [12.3, 12.4],
    ["gesture", "repeatIntervalMs"]: [1234, 1235],
]

private func setting(_ value: Any?, at path: [String], in object: [String: Any]) -> [String: Any] {
    var tree = ConfigTree(object)
    tree.set(value, at: path)
    return tree.root
}

/// The entry key Kit keeps for a mouse among `devices`.
private func rawEntryKey(_ object: [String: Any], _ key: String) -> String? {
    (object["devices"] as? [String: Any])?.keys.sorted().last { $0.lowercased() == key }
}

/// Kit's meaning of "the mouse sets this": resolve the mouse's config on a tree whose top level
/// holds a value of its own for the setting, with and without the mouse's entry holding its value.
/// If taking the entry's value out changes what Kit resolves, the entry sets it.
private func kitSays(_ root: [String: Any], mouse key: String, sets path: [String]) throws -> Bool {
    let entryKey = rawEntryKey(root, key)
    func resolve(_ object: [String: Any]) throws -> Config {
        try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let control = path.count >= 2 && path[0] == "buttons" ? path[1] : nil
    if let control {
        let cid = NamedButton.cid(forKey: control)
        func spells(_ name: String) -> Bool { cid.map { NamedButton.cid(forKey: name) == $0 } ?? (name == control) }
        func strip(_ buttons: Any?) -> [String: Any] {
            (buttons as? [String: Any] ?? [:]).filter { !spells($0.key) }
        }
        let own = ((root["devices"] as? [String: Any])?[entryKey ?? ""] as? [String: Any])?["buttons"] as? [String: Any] ?? [:]
        let ownBinding = own.keys.sorted().last { spells($0) && !(own[$0] is NSNull) }.flatMap { own[$0] }
        // A top-level binding of the control that differs from the mouse's.
        var top: Any
        if path.count == 2 {
            top = ["mute", "launchpad"].first { JSON.encode($0) != JSON.encode(ownBinding as Any) } ?? "mute"
        } else {
            top = [path[2]: ["run": "sentinel \(path[2])"]]
        }
        var withTop = root
        var buttons = strip(root["buttons"])
        buttons[control] = top
        withTop["buttons"] = buttons
        var without = withTop
        if let entryKey, var devices = without["devices"] as? [String: Any], var entry = devices[entryKey] as? [String: Any] {
            entry["buttons"] = strip(entry["buttons"])
            devices[entryKey] = entry
            without["devices"] = devices
        }
        let with = try resolve(withTop).forDevice(key)
        let bare = try resolve(without).forDevice(key)
        func seen(_ kit: Config) -> String {
            let binding = cid.map { kit.bindings[$0] } ?? kit.buttons[control]
            if path.count == 2 || Config.reservedControls.contains(cid ?? 0) { return describe(binding) }
            guard case .gesture(let g)? = binding else { return binding == nil ? "none at all" : "not a gesture" }
            return "\(["click": g.click, "up": g.up, "down": g.down, "left": g.left, "right": g.right][path[2]] as Any)"
        }
        return seen(with) != seen(bare)
    }
    let candidates = try #require(leafSentinels[path])
    let own = (((root["devices"] as? [String: Any])?[entryKey ?? ""] as? [String: Any]).map { ConfigTree($0) })?[path]
    let value = candidates.first { JSON.encode($0) != JSON.encode(own is NSNull ? "" : (own ?? "")) } ?? candidates[0]
    let withTop = setting(value, at: path, in: root)
    var without = withTop
    if let entryKey {
        var tree = ConfigTree(withTop)
        tree.set(nil, at: ["devices", entryKey] + path)
        without = tree.root
        // `set` prunes the objects it empties; an entry is not one Kit needs, but a section is.
        if var devices = without["devices"] as? [String: Any] {
            if devices[entryKey] == nil { devices[entryKey] = [:] as [String: Any] }
            without["devices"] = devices
        }
    }
    return try fingerprint(resolve(withTop).forDevice(key)) != fingerprint(resolve(without).forDevice(key))
}

@Test func isOverriddenAgreesWithWhatKitResolvesOnGeneratedTrees() throws {
    var maker = TreeMaker(rng: SeededGenerator(state: 0x4F76_6572_7269_6465))
    var overridden = 0
    var hidden = 0
    for round in 0..<120 {
        let (config, keys) = maker.tree()
        let note = Comment(rawValue: "round \(round): \(String(decoding: config.data(), as: UTF8.self))")
        for key in keys {
            let scope = device(key)
            var paths = Array(leafSentinels.keys)
            for spellings in TreeMaker.spellings {
                let name = maker.pick(spellings)
                paths.append(["buttons", name])
                for direction in Gesture.directions where maker.chance(0.4) { paths.append(["buttons", name, direction]) }
            }
            for name in TreeMaker.unknownNames {
                paths.append(["buttons", name])
                paths.append(["buttons", name, "up"])
            }
            for path in paths {
                let kit = try kitSays(config.root, mouse: key, sets: path)
                #expect(config.isOverridden(path, in: scope) == kit, "\(path) \(note.rawValue)")
                if kit { overridden += 1 }
                if kit, path.count == 3, path[0] == "buttons" { hidden += 1 }
            }
        }
    }
    #expect(overridden > 300)
    #expect(hidden > 30)
}

// MARK: Writes against Kit

@Test func deviceWritesLeaveTheTopLevelAndTheOtherMiceAloneAndReplayLikeTheDirectEdit() throws {
    var maker = TreeMaker(rng: SeededGenerator(state: 0x5772_6974_6573_2121))
    let paths = Array(leafSentinels.keys).sorted { $0.joined() < $1.joined() }
    var edits = 0
    var created = 0
    var removedEntries = 0
    for round in 0..<300 {
        var (config, keys) = maker.tree()
        // The mouse to edit: one the tree names, or sometimes one it does not.
        let key = maker.chance(0.4) ? maker.deviceKey() : maker.pick(keys)
        let scope = device(key)
        let before = config
        let decodedBefore = try decode(before)
        var log: [String] = []
        var undoers: [(inout ConfigTree) -> Void] = []
        func entries(_ tree: ConfigTree) -> Set<String> {
            Set(((tree[["devices"]] as? [String: Any]) ?? [:]).keys.filter { $0.lowercased() == key })
        }
        var hadEntry = !entries(config).isEmpty
        // A second pass takes back what the first wrote, now and then.
        let forward = maker.int(1...6)
        let takesBack = maker.chance(0.4)
        var step = 0
        while step < forward || (takesBack && !undoers.isEmpty) {
            let undo = step >= forward
            step += 1
            switch undo ? 4 : maker.int(0...3) {
            case 4:
                log.append("undo")
                undoers.removeLast()(&config)
            case 0, 1:
                let path = maker.pick(paths)
                let value: Any? = maker.chance(0.3) ? nil : maker.pick(leafSentinels[path]!)
                log.append("set \(path) \(value as Any)")
                config.set(value, at: path, in: scope, name: "Mouse")
                undoers.append { $0.set(nil, at: path, in: scope) }
            case 2:
                let button = maker.pick(TreeMaker.spellings.flatMap { $0 } + TreeMaker.unknownNames)
                let action = maker.pick([ButtonAction.standard, .named("none"), .named("mute"), .keys("cmd+c"),
                                         .run("open -a Notes"), .haptic(HapticWaveform.allCases[0].rawValue), .gesture])
                log.append("bind \(button) \(action)")
                config.bind(button, to: action, in: scope)
                undoers.append { $0.bind(button, to: .standard, in: scope) }
            default:
                let button = maker.pick(maker.pick(TreeMaker.spellings))
                let direction = maker.pick(Gesture.directions)
                let action = maker.pick([ButtonAction.standard, .named("none"), .named("volumeUp"), .keys("cmd+v"),
                                         .run("open -a Safari"), .haptic(HapticWaveform.allCases[0].rawValue)])
                log.append("bind \(button).\(direction) \(action)")
                config.bind(button, direction: direction, to: action, in: scope)
                undoers.append { $0.bind(button, direction: direction, to: .standard, in: scope) }
            }
            edits += 1
            if !entries(config).isEmpty { hadEntry = true } else if hadEntry { removedEntries += 1; hadEntry = false }
        }
        let note = Comment(rawValue: "round \(round) \(key) \(log)\nbefore: \(String(decoding: before.data(), as: UTF8.self))\nafter: \(String(decoding: config.data(), as: UTF8.self))")
        let decodedAfter = try decode(config)

        // The top level, and every other mouse, resolve as they did.
        #expect(fingerprint(decodedAfter) == fingerprint(decodedBefore), note)
        let others = Set(decodedBefore.devices.keys).subtracting([key])
        #expect(Set(decodedAfter.devices.keys).subtracting([key]) == others, note)
        for other in others {
            #expect(fingerprint(decodedAfter.forDevice(other)) == fingerprint(decodedBefore.forDevice(other)), note)
        }
        // Entry keys: none new for a mouse that had an entry, however its key was spelled.
        if !entries(before).isEmpty { #expect(entries(config).isSubset(of: entries(before)), note) } else { created += entries(config).count }

        // What the tree reads for the mouse is what Kit resolves.
        _ = try expectResolvedMatchesKit(config, key, decodedAfter, note)

        // Replayed onto the tree it started from, the changes make the same edit.
        var replay = before
        replay.apply(before.changes(to: config))
        #expect(replay.data() == config.data(), note)
    }
    #expect(edits > 600)
    #expect(created > 10)
    #expect(removedEntries > 5, "\(removedEntries)")
}

// MARK: The #51 review's two gaps

@Test func removingDPIOnAMixedCaseTwinDoesNotLetTheOtherSpellingApply() throws {
    let key = mouse
    let config = try tree(#"{"devices": {"\#(key.uppercased())": {"dpi": 1600}, "\#(key)": {"dpi": 1200}}}"#)
    // Kit: the last spelling in sorted order applies, and it replaces the earlier entry whole.
    #expect(try decode(config).forDevice(key).dpi == 1200)
    var edited = config
    edited.set(nil, at: ["dpi"], in: device(key))
    // Kit is the oracle: the other spelling's 1600 must not come back.
    #expect(try decode(edited).forDevice(key).dpi != 1600)
    #expect(try decode(edited).forDevice(key).dpi == (try decode(ConfigTree()).forDevice(key).dpi))
    #expect(edited.resolvedInt(["dpi"], in: device(key)) == nil)
    #expect(!edited.isOverridden(["dpi"], in: device(key)))
    // The applying entry stays as a name-only shadow, so Settings and Kit agree.
    #expect(edited.contains(["devices", key]))
    // And with another key on the shadowed spelling, the same: none of its keys apply.
    let richer = try tree(#"{"devices": {"\#(key.uppercased())": {"dpi": 1600, "scrollWheel": {"inverted": true}}, "\#(key)": {"dpi": 1200}}}"#)
    var removed = richer
    removed.set(nil, at: ["dpi"], in: device(key))
    #expect(try decode(removed).forDevice(key).scrollWheel?.inverted == (try decode(ConfigTree()).forDevice(key).scrollWheel?.inverted))
    #expect(removed.resolved(["scrollWheel"], in: device(key)) == nil)
}

@Test func aWholeSectionReadSkipsAKeyTheDeviceSetsToNull() throws {
    let config = try tree(#"{"scrollWheel": {"inverted": true, "mode": "ratchet"}, "devices": {"\#(mouse)": {"scrollWheel": {"inverted": null, "smartShiftThreshold": 20}}}}"#)
    let section = config.resolved(["scrollWheel"], in: device(mouse)) as? [String: Any]
    // A null reads as absent (Kit decodes it as such), so the top level's value stays.
    #expect(section?["inverted"] as? Bool == true)
    #expect(section?["mode"] as? String == "ratchet")
    #expect(section?["smartShiftThreshold"] as? Int == 20)
    let kit = try decode(config).forDevice(mouse).scrollWheel
    #expect(kit?.inverted == true && kit?.smartShiftThreshold == 20)
    #expect(config.resolvedBool(["scrollWheel", "inverted"], in: device(mouse)) == true)
    #expect(!config.isOverridden(["scrollWheel", "inverted"], in: device(mouse)))
}

@Test func theMixedCaseShadowSurvivesTheReplayOfARemovalOntoTheFile() throws {
    let file = try tree(#"{"devices": {"\#(mouse.uppercased())": {"dpi": 1600}, "\#(mouse)": {"dpi": 1200}}}"#)
    var edited = file
    edited.set(nil, at: ["dpi"], in: device(mouse))
    var saved = file
    saved.apply(file.changes(to: edited))
    #expect(try decode(saved).forDevice(mouse).dpi == (try decode(ConfigTree()).forDevice(mouse).dpi))
    #expect(saved.resolvedInt(["dpi"], in: device(mouse)) == nil)
}

@Test func mouseDefaultOnAMouseWhileAllMiceBindsTheButtonIsWrittenAsDefault() throws {
    // The oracle is `Config.forDevice`: Mouse Default on a mouse must resolve to no binding, so the
    // daemon clicks natively there, while "Same as All Mice" (the key removed) inherits.
    var config = try tree(#"{"buttons": {"back": "mute"}, "devices": {"\#(mouse)": {"name": "MX", "buttons": {"back": "launchpad"}}}}"#)
    let d = device(mouse)
    func action() throws -> Action? { if case .action(let a)? = try decode(config).forDevice(mouse).bindings[0x0053] { a } else { nil } }
    #expect(try action() == Action.named["launchpad"])

    config.bind("back", to: .mouseDefault, in: d)
    #expect(config.string(["devices", mouse, "buttons", "back"]) == "default")
    #expect(try decode(config).forDevice(mouse).bindings[0x0053] == nil)
    #expect(try decode(config).forDevice(nil).bindings[0x0053] != nil)
    #expect(config.binding("back", in: d) == .mouseDefault)
    #expect(config.isOverridden(["buttons", "back"], in: d))
    #expect(config.resolved(["buttons", "back"], in: d) == nil)
    #expect(config.resolvedBinding("back", in: d) == .standard)
    #expect(config.scopedButton("back", in: d).own == .mouseDefault)
    #expect(config.scopedButton("back", in: d).directions.isEmpty)
    #expect(config.binding("back") == .named("mute"))

    // Same as All Mice removes the key, and the mouse follows All Mice again.
    config.bind("back", to: .standard, in: d)
    #expect(try action() == Action.named["mute"])
    #expect(!config.isOverridden(["buttons", "back"], in: d))

    // Under All Mice, Mouse Default is no key at all, never a "default" value.
    config.bind("back", to: .mouseDefault)
    #expect(!config.contains(["buttons", "back"]))
    config.bind("forward", to: .mouseDefault)
    #expect(!config.contains(["buttons", "forward"]))
}

@Test func mouseDefaultOnAMouseWorksWithAnotherSpellingAndAnUpperCaseEntry() throws {
    var config = try tree(#"{"buttons": {"back": "mute"}, "devices": {"\#(mouse.uppercased())": {"name": "MX", "buttons": {"0x0053": "launchpad"}}}}"#)
    let d = device(mouse)
    config.bind("back", to: .mouseDefault, in: d)
    #expect(config.string(["devices", mouse.uppercased(), "buttons", "0x0053"]) == "default")
    #expect(!config.contains(["devices", mouse]))
    #expect(try decode(config).forDevice(mouse).bindings[0x0053] == nil)
    #expect(config.resolved(["buttons", "back"], in: d) == nil)
    #expect((config.resolved(["buttons"], in: d) as? [String: Any])?.isEmpty == true)
}

@Test func mouseDefaultOnAMouseThenAGestureStartsFromNothing() throws {
    var config = try tree(#"{"buttons": {"back": "mute"}}"#)
    let d = device(mouse)
    config.bind("back", to: .mouseDefault, in: d)
    config.bind("back", to: .gesture, in: d)
    #expect(config.string(["devices", mouse, "buttons", "back", "click"]) == "none")
    let kit = try decode(config).forDevice(mouse)
    guard case .gesture(let gesture)? = kit.bindings[0x0053] else { Issue.record("gesture"); return }
    #expect(gesture.click == Action.none)
}

@Test func mouseDefaultInAnAppIsTheAppsOwnValueAndReadsAsSet() throws {
    var config = try tree(#"{"buttons": {"back": "mute"}}"#)
    let app = ConfigTree.appScope("com.example.x")
    config.bindInApp("com.example.x", button: "back", to: .mouseDefault)
    #expect(config.string(["apps", "com.example.x", "buttons", "back"]) == "default")
    #expect(config.binding("back", in: app) == .mouseDefault)
    #expect(config.isOverridden(["buttons", "back"], in: app))
    #expect(config.appButton("com.example.x", button: "back").own == .mouseDefault)
    #expect(config.appSummary("com.example.x") == "1 button changed")
    // Kit: native in the app while the global scope binds the button.
    let decoded = try decode(config)
    let settings = try #require(decoded.settings(forApp: "com.example.x"))
    #expect(settings.bindings[0x0053] == nil && settings.buttons.contains(0x0053))
    #expect(decoded.global.bindings[0x0053] != nil)
    // A gesture there starts with a click that does nothing, not "default".
    config.bindInApp("com.example.x", button: "back", to: .gesture)
    #expect(config.string(["apps", "com.example.x", "buttons", "back", "click"]) == "none")
    config.bindInApp("com.example.x", button: "back", to: .mouseDefault)
    config.bindInApp("com.example.x", button: "back", to: .standard)
    #expect(!config.hasApp("com.example.x"))
}
