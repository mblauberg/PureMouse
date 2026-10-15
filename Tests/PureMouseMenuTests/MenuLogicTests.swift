import Foundation
import PureMouseKit
import Testing
@testable import PureMouseMenu

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func text(_ tree: ConfigTree) -> String { String(decoding: tree.data(), as: UTF8.self) }

// MARK: ConfigTree

@Test func setCreatesIntermediateObjectsAndKeepsUnknownKeys() throws {
    var config = try tree(#"{"future": {"x": 1}, "dpi": 1600}"#)
    config.set(0.7, at: ["smoothScroll", "speed"])
    #expect(config.double(["smoothScroll", "speed"]) == 0.7)
    #expect(config.int(["future", "x"]) == 1)
    #expect(config.int(["dpi"]) == 1600)
}

@Test func removingTheLastKeyPrunesEmptyObjects() throws {
    var config = try tree(#"{"scrollWheel": {"inverted": true}, "gesture": {"distanceMm": 5}}"#)
    config.set(nil, at: ["scrollWheel", "inverted"])
    config.set(nil, at: ["gesture", "distanceMm"])
    #expect(config.root.isEmpty)
}

@Test func emptySmoothScrollIsKept() throws {
    var config = try tree(#"{"smoothScroll": {"speed": 2}}"#)
    config.set(nil, at: ["smoothScroll", "speed"])
    #expect(config.contains(["smoothScroll"]))
    #expect(config.smoothScrollEnabled)
}

@Test func removingAMissingPathChangesNothing() throws {
    var config = try tree(#"{"dpi": 800}"#)
    config.set(nil, at: ["buttons", "back"])
    #expect(config.root.keys.sorted() == ["dpi"])
}

@Test func emptyFileIsAnEmptyConfig() throws {
    #expect(try tree(" \n").root.isEmpty)
    #expect(throws: (any Error).self) { try tree("[1]") }
}

@Test func typedReadsTellBoolsFromNumbers() throws {
    let config = try tree(#"{"a": true, "b": 1, "c": 0.5}"#)
    #expect(config.bool(["a"]) == true)
    #expect(config.bool(["b"]) == nil)
    #expect(config.int(["a"]) == nil)
    #expect(config.int(["b"]) == 1)
    #expect(config.int(["c"]) == nil)
    #expect(config.double(["c"]) == 0.5)
}

// MARK: JSON writer

@Test func encoderWritesShortestDecimalsSortedKeysAndBools() throws {
    var config = ConfigTree()
    config.set(0.7, at: ["smoothScroll", "speed"])
    config.set(true, at: ["scrollWheel", "inverted"])
    config.set(1600, at: ["dpi"])
    config.set([800, 1600], at: ["dpiPresets"])
    config.set("cmd+w", at: ["buttons", "middle", "keys"])
    #expect(text(config) == """
    {
      "buttons": {
        "middle": {
          "keys": "cmd+w"
        }
      },
      "dpi": 1600,
      "dpiPresets": [800, 1600],
      "scrollWheel": {
        "inverted": true
      },
      "smoothScroll": {
        "speed": 0.7
      }
    }

    """)
}

@Test func encoderRoundTripsParsedNumbers() throws {
    let config = try tree(#"{"a": 0.1, "b": 2.0, "c": 3, "d": false, "e": "x\"y\n", "f": {}}"#)
    let output = text(config)
    #expect(output.contains(#""a": 0.1,"#))
    #expect(output.contains(#""b": 2,"#))
    #expect(output.contains(#""d": false,"#))
    #expect(output.contains(#""e": "x\"y\n","#))
    #expect(output.contains(#""f": {}"#))
    let reparsed = try ConfigTree(data: config.data())
    #expect(reparsed.bool(["d"]) == false)
    #expect(reparsed.string(["e"]) == "x\"y\n")
}

// MARK: Actions

@Test func buttonActionsReadEveryJSONForm() {
    #expect(ButtonAction(json: nil) == .standard)
    #expect(ButtonAction(json: "missionControl") == .named("missionControl"))
    #expect(ButtonAction(json: ["keys": "cmd+w"]) == .keys("cmd+w"))
    #expect(ButtonAction(json: ["run": "say hi"]) == .run("say hi"))
    #expect(ButtonAction(json: ["click": "none", "up": "spaceLeft"]) == .gesture)
    #expect(ButtonAction(json: [String: Any]()) == .named("?"))
}

@Test func buttonActionLabels() {
    #expect(ButtonAction.standard.label == "Default")
    #expect(ButtonAction.named("none").label == "Do Nothing")
    #expect(ButtonAction.named("cycleDPI").label == "Cycle Pointer Speed")
    #expect(ButtonAction.named("toggleScrollMode").label == "Switch Wheel Mode")
    #expect(ButtonAction.keys("cmd+w").label == "⌘W")
    #expect(ButtonAction.run("open -a Safari").label == "open -a Safari")
    #expect(ButtonAction.gesture.label == "Hold and Move")
    #expect(ButtonAction.named("futureAction").label == "futureAction")
}

@Test func bindingAGestureNeverLeavesItEmpty() {
    var config = ConfigTree()
    config.bind("gesture", to: .gesture)
    #expect(config.binding("gesture") == .gesture)
    #expect(config.string(["buttons", "gesture", "click"]) == "none")

    // The click keeps what the button did.
    config.bind("top", to: .named("showDesktop"))
    config.bind("top", to: .gesture)
    #expect(config.string(["buttons", "top", "click"]) == "showDesktop")

    // Clearing the last direction leaves "none", not {}.
    config.bind("gesture", direction: "click", to: .named("none"))
    #expect(config.binding("gesture") == .gesture)
    config.bind("gesture", direction: "up", to: .named("spaceLeft"))
    config.bind("gesture", direction: "click", to: .standard)
    #expect(config.self[["buttons", "gesture", "click"]] == nil)
    config.bind("gesture", direction: "up", to: .standard)
    #expect(config.string(["buttons", "gesture", "up"]) == "none")
    #expect(config.binding("gesture") == .gesture)
}

@Test func bindingDefaultRemovesTheKey() {
    var config = ConfigTree()
    config.bind("back", to: .keys("cmd+["))
    #expect(config.binding("back") == .keys("cmd+["))
    config.bind("back", to: .standard)
    #expect(config.root.isEmpty)
}

@Test func namedButtonKeys() {
    #expect(NamedButton.cid(forKey: "back") == 0x53)
    #expect(NamedButton.cid(forKey: "0x00c4") == 0xC4)
    #expect(NamedButton.config(cid: 0x56) == "forward")
    #expect(NamedButton.config(cid: 0x1A0) == "0x01a0")
}

// MARK: Shortcuts

@Test func shortcutSpecsFromKeyPresses() {
    #expect(Shortcut.spec(keyCode: 21, modifiers: [.command, .shift]) == "shift+cmd+4")
    #expect(Shortcut.spec(keyCode: 123, modifiers: [.control]) == "ctrl+left")
    #expect(Shortcut.spec(keyCode: 122, modifiers: []) == "f1")
    #expect(Shortcut.spec(keyCode: 999, modifiers: [.command]) == nil)
}

@Test func shortcutParsingAndDisplay() {
    #expect(Shortcut.display("cmd+shift+4") == "⇧⌘4")
    #expect(Shortcut.display("ctrl+left") == "⌃←")
    #expect(Shortcut.display("Alt+Space") == "⌥Space")
    #expect(Shortcut.display("cmd+f11") == "⌘F11")
    #expect(Shortcut.spoken("cmd+shift+4") == "Shift Command 4")
    #expect(Shortcut.isValid("fn+f5"))
    #expect(!Shortcut.isValid("cmd"))
    #expect(!Shortcut.isValid("cmd+a+b"))
    #expect(!Shortcut.isValid("hyper+a"))
    #expect(!Shortcut.isValid(""))
    // The daemon's own parser decides: no padding, empty parts skipped, fn accepted.
    #expect(!Shortcut.isValid("cmd + 4"))
    #expect(Shortcut.display("cmd++4") == "⌘4")
    #expect(Shortcut.display("fn+cmd+left") == "⌘←")
    #expect(Shortcut.display("cmd+enter") == "⌘↩")
}

// MARK: Presets

@Test func feelMatchesPresetsWithDaemonDefaults() {
    #expect(Feel.matching(acceleration: nil, smoothingMs: nil) == .balanced)
    #expect(Feel.matching(acceleration: 0.5, smoothingMs: 60) == .precise)
    #expect(Feel.matching(acceleration: 1.2, smoothingMs: 350) == .gliding)
    #expect(Feel.matching(acceleration: 1.2, smoothingMs: 300) == .custom)
}

@Test func applyingAFeelWritesBothKeys() {
    var config = ConfigTree()
    config.apply(.gliding)
    #expect(config.feel == .gliding)
    #expect(config.double(["smoothScroll", "smoothingMs"]) == 350)
    config.apply(.custom)
    #expect(config.feel == .gliding)
}

@Test func dpiPresetListsStaySortedUniqueAndBounded() {
    #expect(DPIPresets.adding(800, to: [1600, 3200]) == [800, 1600, 3200])
    #expect(DPIPresets.adding(1600, to: [1600]) == [1600])
    let full = Array(stride(from: 400, through: 3200, by: 400))
    #expect(full.count == DPIPresets.limit)
    #expect(DPIPresets.adding(100, to: full) == full)
    #expect(DPIPresets.removing(1600, from: [800, 1600]) == [800])
    #expect(DPIPresets.snap(1630, to: [1600, 1650, 1700]) == 1650)
}

private func mouse(_ id: String, online: Bool, dpi: Int?, steps: [Int] = []) -> Status.Device {
    Status.Device(id: id, name: id, connection: .receiver, online: online, battery: nil, dpi: dpi, dpiSteps: steps,
                  wheelMode: nil, hasSmartShift: false, hasThumbWheel: false, controls: [])
}

@Test func dpiShowsTheLiveValueOverTheConfiguredOne() {
    var reading = DPIReading()
    // A Cycle Pointer Speed press moved the mouse to 3200; the config still says 1600.
    #expect(reading.current(live: 3200, configured: 1600) == 3200)
    #expect(reading.current(live: nil, configured: 1600) == 1600)
    #expect(reading.current(live: nil, configured: nil) == 1000)

    // A change made here shows at once, survives a stale report, and clears once confirmed.
    let start = Date(timeIntervalSinceReferenceDate: 0)
    reading.request(800, at: start)
    #expect(reading.current(live: 3200, configured: 1600) == 800)
    reading.reported(3200, steps: [800, 1600, 3200], at: start.addingTimeInterval(0.2))
    #expect(reading.requested == 800)
    reading.reported(800, steps: [800, 1600, 3200], at: start.addingTimeInterval(0.4))
    #expect(reading.requested == nil)

    // A request the sensor snaps is confirmed by the snapped value.
    reading.request(830, at: start)
    reading.reported(850, steps: [800, 850, 900], at: start.addingTimeInterval(0.2))
    #expect(reading.requested == nil)

    // A later, different report (a button press) wins.
    reading.request(800, at: start)
    reading.reported(1600, steps: [800, 1600], at: start.addingTimeInterval(DPIReading.settle + 1))
    #expect(reading.current(live: 1600, configured: 800) == 1600)
}

@Test func aSensorWithOneSettingNeverIndexesOutOfRange() {
    #expect(DPIReading.index(of: 4000, in: [1000]) == 0)
    #expect(DPIReading.step(at: 1, in: [1000]) == 1000)
    #expect(DPIReading.step(at: -3, in: [1000]) == 1000)
    #expect(DPIReading.step(at: 0.4, in: []) == nil)
    #expect(DPIReading.index(of: 1000, in: []) == 0)
    #expect(DPIReading.step(at: 2.6, in: [400, 800, 1600]) == 1600)
}

@Test func twoMiceWithDifferentDPI() {
    let asleep = mouse("a", online: false, dpi: 800, steps: [800])
    let awake = mouse("b", online: true, dpi: 1600, steps: [1600, 3200])
    // The live value and the slider's steps come from the same mouse: the first one online.
    #expect(AppModel.live(of: [asleep, awake])?.dpi == 1600)
    #expect(AppModel.primary(of: [asleep, awake])?.dpiSteps == [1600, 3200])
    let other = mouse("c", online: true, dpi: 3200)
    #expect(AppModel.live(of: [other, awake])?.dpi == 3200)
    #expect(AppModel.live(of: [asleep]) == nil && AppModel.primary(of: [asleep])?.dpi == 800)
}

@Test func dpiPresetsKeyIsRemovedWhenEmpty() {
    var config = ConfigTree()
    config.dpiPresets = [800]
    #expect(config.dpiPresets == [800])
    config.dpiPresets = []
    #expect(!config.contains(["dpiPresets"]))
}

@Test func smoothScrollToggleKeepsTuning() throws {
    var config = ConfigTree()
    #expect(!config.smoothScrollEnabled)
    config.smoothScrollEnabled = true
    #expect(text(config).contains(#""smoothScroll": {}"#))

    config = try tree(#"{"smoothScroll": {"speed": 1.5}}"#)
    config.smoothScrollEnabled = false
    #expect(config.bool(["smoothScroll", "enabled"]) == false)
    #expect(config.double(["smoothScroll", "speed"]) == 1.5)
    config.smoothScrollEnabled = true
    #expect(!config.contains(["smoothScroll", "enabled"]))
    #expect(config.double(["smoothScroll", "speed"]) == 1.5)
}

@Test func formatting() {
    #expect(Format.snap(0.7500000001, step: 0.05) == 0.75)
    #expect(Format.snap(0.69999, step: 0.1) == 0.7)
    #expect(Format.milliseconds(124.6) == "125 ms")
}

@MainActor @Test func everyRecordableKeyPassesTheDaemonsCheck() {
    for name in Set(Keystroke.keyNames.values) {
        #expect(ShortcutCheck.isValid("cmd+" + name), "cmd+\(name)")
    }
    #expect(!ShortcutCheck.isValid("cmd+nosuchkey"))
}

// MARK: Review fixes

@Test func untouchedNumbersKeepTheirExactDigits() throws {
    let config = try tree(#"{"big": 18446744073709551617, "neg": -9223372036854775809, "tenth": 0.1, "n": 5, "huge": 9007199254740993}"#)
    let out = text(config)
    #expect(out.contains(#""big": 18446744073709551617"#))
    #expect(out.contains(#""neg": -9223372036854775809"#))
    #expect(out.contains(#""tenth": 0.1"#))
    #expect(out.contains(#""n": 5,"#) || out.contains(#""n": 5\#n"#))
    #expect(out.contains(#""huge": 9007199254740993"#))
    #expect(config.int(["huge"]) == 9007199254740993)
    #expect(config.int(["big"]) == nil)
    #expect(config.int(["n"]) == 5)
}

@Test func replayingChangesKeepsAHandEditElsewhere() throws {
    let loaded = try tree(#"{"buttons": {"back": "missionControl"}, "dpi": 800}"#)
    var edited = loaded
    edited.bind("back", to: .standard)
    edited.set(1600, at: ["dpi"])
    let changes = loaded.changes(to: edited)
    // Meanwhile the file gained a binding for forward and a new speed, and back was rebound.
    var fresh = try tree(#"{"buttons": {"back": "appExpose", "forward": "showDesktop"}, "dpi": 800, "smoothScroll": {"speed": 2}}"#)
    fresh.apply(changes)
    #expect(fresh[["buttons", "back"]] == nil)
    #expect(fresh.string(["buttons", "forward"]) == "showDesktop")
    #expect(fresh.int(["dpi"]) == 1600)
    #expect(fresh.double(["smoothScroll", "speed"]) == 2)
}

@Test func replayingAToggleSetsItsValueRatherThanFlipping() throws {
    let loaded = try tree(#"{"smoothScroll": {}}"#)
    var edited = loaded
    edited.smoothScrollEnabled.toggle()
    var fresh = try tree(#"{"smoothScroll": {"enabled": false, "speed": 2}}"#)
    fresh.apply(loaded.changes(to: edited))
    #expect(fresh.smoothScrollEnabled == false)
    #expect(fresh.double(["smoothScroll", "speed"]) == 2)
    #expect(loaded.changes(to: loaded).isEmpty)
}

@Test func hexKeysForNamedControlsAreReadAndEditedInPlace() throws {
    var config = try tree(#"{"buttons": {"0x0053": "missionControl", "c5": "appExpose"}}"#)
    #expect(config.binding("back") == .named("missionControl"))
    config.bind("back", to: .named("showDesktop"))
    #expect((config[["buttons"]] as? [String: Any])?.keys.sorted() == ["0x0053", "c5"])
    #expect(config.string(["buttons", "0x0053"]) == "showDesktop")
    #expect(config.binding("0x00c5") == .named("appExpose"))
    config.bind("back", to: .standard)
    #expect((config[["buttons"]] as? [String: Any])?.keys.sorted() == ["c5"])
}

@Test func otherControlsSkipNamedOnesAndDuplicates() {
    let rows = ButtonRows.others(deviceCIDs: [0x0053, 0x00c5, 0x00d7],
                                 configKeys: ["0x0053", "back", "0xC5", "1a0", "nonsense"])
    #expect(rows == ["0x00c5", "0x00d7", "1a0"])
}

// MARK: Saving

private func tempConfig(_ json: String?) throws -> ConfigFile {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "config.json")
    if let json { try Data(json.utf8).write(to: url) }
    return ConfigFile(url: url)
}

@Test func savingKeepsAHandEditMadeAfterLoading() throws {
    let file = try tempConfig(#"{"dpi": 800}"#)
    let loaded = try ConfigTree(data: Data(contentsOf: file.url))
    var edited = loaded
    edited.set(true, at: ["scrollWheel", "inverted"])
    // Edited by hand before the app saves.
    try Data(#"{"dpi": 1200, "buttons": {"back": "appExpose"}}"#.utf8).write(to: file.url)
    let saved = try file.save(loaded.changes(to: edited))
    let disk = try ConfigTree(data: Data(contentsOf: file.url))
    #expect(disk.int(["dpi"]) == 1200)
    #expect(disk.string(["buttons", "back"]) == "appExpose")
    #expect(disk.bool(["scrollWheel", "inverted"]) == true)
    #expect(saved.data == (try Data(contentsOf: file.url)))
}

@Test func savingRefusesToBuildOnABrokenFile() throws {
    let broken = #"{"dpi": "#
    let file = try tempConfig(broken)
    #expect(throws: (any Error).self) { try file.save([ConfigTree.Change(path: ["dpi"], value: 800)]) }
    #expect(String(decoding: try Data(contentsOf: file.url), as: UTF8.self) == broken)
}

@Test func savingAnInvalidValueWritesNothing() throws {
    let file = try tempConfig(#"{"dpi": 800}"#)
    #expect(throws: (any Error).self) { try file.save([ConfigTree.Change(path: ["dpi"], value: 999_999)]) }
    #expect(try ConfigTree(data: Data(contentsOf: file.url)).int(["dpi"]) == 800)
}

@Test func savingWithoutAFileCreatesOne() throws {
    let file = try tempConfig(nil)
    let saved = try file.save([ConfigTree.Change(path: ["dpi"], value: 1600)])
    #expect(saved.tree.int(["dpi"]) == 1600)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}
