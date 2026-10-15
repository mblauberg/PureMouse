import Foundation
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
    #expect(ButtonAction.gesture.label == "Hold and move")
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
    #expect(DPIPresets.next(after: 1600, in: [800, 1600, 3200]) == 3200)
    #expect(DPIPresets.next(after: 3200, in: [800, 1600, 3200]) == 800)
    #expect(DPIPresets.next(after: 1000, in: []) == nil)
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
    for name in Set(Shortcut.keyNames.values) {
        #expect(ShortcutCheck.isValid("cmd+" + name), "cmd+\(name)")
    }
    #expect(!ShortcutCheck.isValid("cmd+nosuchkey"))
}
