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

    mutating func binding() -> Any {
        guard chance(0.35) else { return action() }
        var gesture: [String: Any] = [:]
        for direction in Gesture.directions where chance(0.5) { gesture[direction] = action() }
        return gesture.isEmpty ? ["click": action()] : gesture
    }

    mutating func buttons() -> [String: Any] {
        var out: [String: Any] = [:]
        for spellings in Self.spellings where chance(0.4) {
            for name in spellings where out.isEmpty || chance(0.7) || name == spellings[0] {
                if chance(0.8) { out[name] = binding() }
            }
        }
        for name in Self.unknownNames where chance(0.15) { out[name] = action() }
        return out
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
            out["smoothScroll"] = smooth
        }
        if chance(0.7) { out["buttons"] = buttons() }
        if chance(0.5) {
            var gesture: [String: Any] = [:]
            if chance(0.6) { gesture["distanceMm"] = Double(int(5...500)) / 10 }
            if chance(0.6) { gesture["repeatIntervalMs"] = int(0...5000) }
            out["gesture"] = gesture
        }
        return out
    }

    mutating func deviceKey() -> String {
        if chance(0.3) { return "p" + String(format: "%04x", int(1...0xFFFE)) }
        return "m" + (0..<6).map { _ in String(format: "%02x", int(1...0xFE)) }.joined()
    }

    mutating func tree() -> (tree: ConfigTree, keys: [String]) {
        var root = scope()
        var devices: [String: Any] = [:]
        for _ in 0..<int(1...3) {
            var entry = scope()
            if chance(0.5) { entry["name"] = "Mouse \(int(1...99))" }
            devices[deviceKey()] = entry
        }
        root["devices"] = devices
        return (ConfigTree(root), devices.keys.sorted())
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

@Test func resolvedAgreesWithKitsDeviceConfigOnGeneratedTrees() throws {
    var maker = TreeMaker(rng: SeededGenerator(state: 0x5075_7265_4D6F_7573))
    var devicesChecked = 0
    var gesturesMerged = 0
    for round in 0..<400 {
        let (config, keys) = maker.tree()
        let note = Comment(rawValue: "round \(round): \(String(decoding: config.data(), as: UTF8.self))")
        let decoded = try JSONDecoder().decode(Config.self, from: config.data())
        for key in keys {
            let scope = device(key)
            let kit = decoded.forDevice(key)
            devicesChecked += 1

            // Scalars replace, and the preset list replaces whole.
            #expect(config.resolved(["dpi"], in: scope) as? Int == kit.dpi, note)
            #expect((config.resolved(["dpiPresets"], in: scope) as? [Int] ?? []) == kit.dpiPresets, note)

            // scrollWheel, per key.
            let wheel = kit.scrollWheel
            #expect(config.resolved(["scrollWheel", "inverted"], in: scope) as? Bool == wheel?.inverted, note)
            #expect(config.resolved(["scrollWheel", "mode"], in: scope) as? String == wheel?.mode?.rawValue, note)
            #expect(config.resolved(["scrollWheel", "smartShiftThreshold"], in: scope) as? Int
                    == wheel?.smartShiftThreshold.map(Int.init), note)
            #expect((config.resolved(["scrollWheel"], in: scope) != nil) == (wheel != nil), note)

            // thumbWheel: `inverted` per key; the rest layered, since `action` resets the step.
            #expect(config.resolved(["thumbWheel", "inverted"], in: scope) as? Bool == kit.thumbWheel?.inverted, note)
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
            func number(_ name: String) -> Double? {
                (config.resolved(["smoothScroll", name], in: scope) as? Double) ?? (config.resolved(["smoothScroll", name], in: scope) as? Int).map(Double.init)
            }
            if let smooth {
                #expect((config.resolved(["smoothScroll", "enabled"], in: scope) as? Bool ?? fallback.enabled) == smooth.enabled, note)
                #expect((number("speed") ?? fallback.speed) == smooth.speed, note)
                #expect((number("horizontalSpeed") ?? fallback.horizontalSpeed) == smooth.horizontalSpeed, note)
                #expect((number("acceleration") ?? fallback.acceleration) == smooth.acceleration, note)
                #expect((number("smoothingMs") ?? fallback.smoothingMs) == smooth.smoothingMs, note)
                #expect((config.resolved(["smoothScroll", "shiftScrollsHorizontally"], in: scope) as? Bool
                         ?? fallback.shiftScrollsHorizontally) == smooth.shiftScrollsHorizontally, note)
            }

            // gesture, per key.
            let gestureDefaults = Config.GestureSettings()
            func gestureNumber(_ name: String) -> Double? {
                (config.resolved(["gesture", name], in: scope) as? Double) ?? (config.resolved(["gesture", name], in: scope) as? Int).map(Double.init)
            }
            #expect((gestureNumber("distanceMm") ?? gestureDefaults.distanceMm) == kit.gesture.distanceMm, note)
            #expect(Int(gestureNumber("repeatIntervalMs") ?? Double(gestureDefaults.repeatIntervalMs)) == kit.gesture.repeatIntervalMs, note)

            // buttons: per control, whichever way it is spelled, and per direction in a gesture.
            var cids = Set<UInt16>()
            for spellings in TreeMaker.spellings {
                let cid = try #require(NamedButton.cid(forKey: spellings[0]))
                cids.insert(cid)
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
            let all = config.resolved(["buttons"], in: scope) as? [String: Any] ?? [:]
            var named = Set<UInt16>()
            for (name, json) in all {
                guard let cid = NamedButton.cid(forKey: name) else { continue }
                named.insert(cid)
                #expect(describe(try decodeBinding(json)) == describe(kit.bindings[cid]), "\(name) \(note.rawValue)")
            }
            #expect(named == Set(kit.bindings.keys), note)
            #expect(Set(all.keys.filter { NamedButton.cid(forKey: $0) == nil }) == Set(kit.buttons.keys.filter { Config.Button.cid(for: $0) == nil }), note)
        }
    }
    // The generator reaches the interesting cases.
    #expect(devicesChecked > 400)
    #expect(gesturesMerged > 100)
}
