import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// The main wheel's rows always show a value, and write a key only when the choice differs from
// what the scope would have without it (#146.2).

private let key = "mb03400000000"
private let mouse = ConfigScope.device(key)!
private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }

// MARK: What an unset row shows

@Test func unsetRowsShowNotReversedTheMouseReportedModeAndSmartShiftOn() {
    let config = ConfigTree()
    for scope in [ConfigScope.global, mouse] {
        #expect(!WheelDefaults.isReversed(config, in: scope))
        #expect(WheelDefaults.smartShiftIsOn(config, in: scope))
        #expect(WheelDefaults.mode(config, in: scope, live: .freespin) == .freespin)
        #expect(WheelDefaults.mode(config, in: scope, live: .ratchet) == .ratchet)
        #expect(WheelDefaults.mode(config, in: scope, live: nil) == .ratchet)
    }
}

@Test func setValuesWinOverTheDefaultsAndAMouseReadsAllMicesValue() throws {
    let config = try tree(#"""
    {"scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 255},
     "devices": {"mb03400000000": {"scrollWheel": {"mode": "ratchet"}}}}
    """#)
    #expect(WheelDefaults.isReversed(config, in: .global) && WheelDefaults.isReversed(config, in: mouse))
    #expect(!WheelDefaults.smartShiftIsOn(config, in: .global) && !WheelDefaults.smartShiftIsOn(config, in: mouse))
    #expect(WheelDefaults.mode(config, in: .global, live: .ratchet) == .freespin)
    #expect(WheelDefaults.mode(config, in: mouse, live: .freespin) == .ratchet)
    // A mode the daemon would not accept reads as unset.
    let bad = try tree(#"{"scrollWheel": {"mode": "spin"}}"#)
    #expect(WheelDefaults.mode(bad, in: .global, live: .freespin) == .freespin)
}

// MARK: What a choice writes

@Test func theTopLevelAlwaysWritesTheChosenValueEvenWhenItIsTheDefault() {
    // The daemon leaves the mouse as it last set it, so removing a key would not undo it: Reverse off
    // with smooth scrolling off keeps the hardware's direction, SmartShift on is applied only when set.
    var config = ConfigTree()
    WheelDefaults.chooseReversed(false, in: &config, scope: .global)
    WheelDefaults.chooseSmartShift(true, in: &config, scope: .global)
    #expect(config.bool(["scrollWheel", "inverted"]) == false)
    #expect(config.int(["scrollWheel", "smartShiftThreshold"]) == 12)

    WheelDefaults.chooseReversed(true, in: &config, scope: .global)
    WheelDefaults.chooseSmartShift(false, in: &config, scope: .global)
    WheelDefaults.chooseMode(.ratchet, in: &config, scope: .global)
    #expect(config.bool(["scrollWheel", "inverted"]) == true)
    #expect(config.int(["scrollWheel", "smartShiftThreshold"]) == 255)
    #expect(config.string(["scrollWheel", "mode"]) == "ratchet")

    // Turning them back writes again: off for Reverse, 12 for SmartShift.
    WheelDefaults.chooseReversed(false, in: &config, scope: .global)
    WheelDefaults.chooseSmartShift(true, in: &config, scope: .global)
    #expect(config.bool(["scrollWheel", "inverted"]) == false)
    #expect(config.int(["scrollWheel", "smartShiftThreshold"]) == 12)
}

@Test func theTopLevelAlwaysWritesTheChosenModeWhateverTheMouseReports() throws {
    // The daemon does not restore the mouse's own mode when the key goes: removing it would leave
    // free spin on the mouse while Settings showed Ratchet.
    for live in [nil, WheelDefaults.Mode.ratchet, .freespin] {
        var config = try tree(#"{"scrollWheel": {"mode": "freespin"}}"#)
        WheelDefaults.chooseMode(.ratchet, in: &config, scope: .global)
        #expect(config.string(["scrollWheel", "mode"]) == "ratchet", "live \(String(describing: live))")
        WheelDefaults.chooseMode(.freespin, in: &config, scope: .global)
        #expect(config.string(["scrollWheel", "mode"]) == "freespin")
        #expect(WheelDefaults.mode(config, in: .global, live: live) == .freespin)
    }
    // Even the mode the mouse reports is written on a fresh config.
    var fresh = ConfigTree()
    WheelDefaults.chooseMode(.ratchet, in: &fresh, scope: .global)
    #expect(fresh.string(["scrollWheel", "mode"]) == "ratchet")
    // A mouse with nothing explicit above it writes too.
    var other = ConfigTree()
    WheelDefaults.chooseMode(.ratchet, in: &other, scope: mouse)
    #expect(other.string(other.prefix(of: mouse) + ["scrollWheel", "mode"]) == "ratchet")
}

@Test func aMouseDropsItsKeyOnlyForAnExplicitAllMiceValueItEquals() throws {
    var config = try tree(#"{"scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 255}}"#)
    // Equal to All Mice's value: no key under the mouse.
    WheelDefaults.chooseReversed(true, in: &config, scope: mouse)
    WheelDefaults.chooseMode(.freespin, in: &config, scope: mouse)
    WheelDefaults.chooseSmartShift(false, in: &config, scope: mouse)
    #expect(config[["devices"]] == nil)
    // Different from All Mice's: written under the mouse, and All Mice's is untouched.
    WheelDefaults.chooseReversed(false, in: &config, scope: mouse)
    WheelDefaults.chooseMode(.ratchet, in: &config, scope: mouse)
    WheelDefaults.chooseSmartShift(true, in: &config, scope: mouse)
    let path = config.prefix(of: mouse) + ["scrollWheel"]
    #expect(config.bool(path + ["inverted"]) == false)
    #expect(config.string(path + ["mode"]) == "ratchet")
    // SmartShift on over an inherited off writes 12.
    #expect(config.int(path + ["smartShiftThreshold"]) == 12)
    #expect(config.bool(["scrollWheel", "inverted"]) == true && config.int(["scrollWheel", "smartShiftThreshold"]) == 255)
    // Choosing what All Mice has removes the mouse's keys again, and its emptied entry goes.
    WheelDefaults.chooseReversed(true, in: &config, scope: mouse)
    WheelDefaults.chooseMode(.freespin, in: &config, scope: mouse)
    WheelDefaults.chooseSmartShift(false, in: &config, scope: mouse)
    config.settleEntry(for: mouse, name: nil)
    #expect(config[["devices"]] == nil)
}

@Test func aMouseUnderAnUnsetAllMiceWritesItsChoiceToo() throws {
    var config = ConfigTree()
    WheelDefaults.chooseSmartShift(true, in: &config, scope: mouse)
    WheelDefaults.chooseReversed(false, in: &config, scope: mouse)
    let path = config.prefix(of: mouse) + ["scrollWheel"]
    #expect(config.int(path + ["smartShiftThreshold"]) == 12)
    #expect(config.bool(path + ["inverted"]) == false)
    WheelDefaults.chooseSmartShift(false, in: &config, scope: mouse)
    #expect(config.int(path + ["smartShiftThreshold"]) == 255)
}

@MainActor @Test func theRowsWriteThroughTheModelsScopeTarget() throws {
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI/ScrollingPane.swift"), encoding: .utf8)
    for call in ["chooseReversed", "chooseMode", "chooseSmartShift"] {
        let lines = source.components(separatedBy: "\n").filter { $0.contains("WheelDefaults.\(call)(") }
        #expect(lines.count == 1 && lines[0].contains("&$0") && lines[0].contains("scope: scope"), "\(call)")
    }
    #expect(source.contains("let scope = model.scope, target = model.scopeTarget"))
}
