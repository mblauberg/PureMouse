import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// Mouse › Buttons and Scrolling: what shows by default, what Advanced… holds, which controls the
// mouse can use, and what Restore Defaults clears.

private func mouse(_ capabilities: Status.Device.Capabilities?, online: Bool = true) -> Status.Device {
    Status.Device(id: "r1:1", name: "MX", connection: .receiver, online: online, battery: nil, dpi: nil, dpiSteps: [],
                  wheelMode: nil, controls: [], capabilities: capabilities)
}

private let mxMaster3S = Status.Device.Capabilities(dpi: true, smartShift: true, smoothScroll: true, thumbWheel: true)
private let m750 = Status.Device.Capabilities(dpi: true, smartShift: false, smoothScroll: true, thumbWheel: false)
private let noWheels = Status.Device.Capabilities(dpi: true, smartShift: false, smoothScroll: false, thumbWheel: false)

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }

// MARK: Buttons

@Test func theGestureRowSummarisesItsDirections() throws {
    #expect(GestureSummary.text(click: .named("missionControl"), directionsSet: 4) == "Click: Mission Control, 4 directions set.")
    #expect(GestureSummary.text(click: .named("none"), directionsSet: 0) == "Click: Do Nothing, no directions set.")
    #expect(GestureSummary.text(click: .standard, directionsSet: 1) == "Click: Do Nothing, 1 direction set.")
    var config = ConfigTree()
    config.bind("gesture", to: .gesture)
    #expect(config.gestureSummary("gesture") == "Click: Do Nothing, no directions set.")
    let set = try tree(#"{"buttons": {"gesture": {"click": "missionControl", "up": "spaceLeft", "down": "none", "left": {"keys": "cmd+w"}}}}"#)
    #expect(set.gestureSummary("gesture") == "Click: Mission Control, 2 directions set.")
}

@Test func advancedOnButtonsNeedsSomeHoldAndMoveButton() throws {
    #expect(!ConfigTree().usesGestures)
    #expect(!(try tree(#"{"buttons": {"back": "missionControl"}, "gesture": {"distanceMm": 6}}"#)).usesGestures)
    #expect(try tree(#"{"buttons": {"gesture": {"click": "none"}}}"#).usesGestures)
    #expect(try tree(#"{"apps": {"com.apple.Safari": {"buttons": {"top": {"up": "nextTab"}}}}}"#).usesGestures)
    #expect(try tree(#"{"devices": {"m1234": {"buttons": {"0x00c3": {"click": "none"}}}}}"#).usesGestures)
}

@Test func restoreDefaultsOnButtonsClearsButtonsAndGestureOnly() throws {
    var config = try tree(#"""
    {"buttons": {"back": "missionControl", "gesture": {"click": "none", "up": "spaceLeft"}},
     "gesture": {"distanceMm": 6, "repeatIntervalMs": 300},
     "apps": {"com.apple.Safari": {"buttons": {"top": "nextTab"}}}, "dpi": 1600}
    """#)
    config.restoreButtonDefaults()
    #expect(config[["buttons"]] == nil && config[["gesture"]] == nil)
    #expect(config.string(["apps", "com.apple.Safari", "buttons", "top"]) == "nextTab")
    #expect(config.int(["dpi"]) == 1600)
}

// MARK: Scrolling

@Test func restoreDefaultsOnScrollingClearsWhatItAndItsSheetShow() throws {
    var config = try tree(#"""
    {"smoothScroll": {"speed": 2, "acceleration": 0.3, "smoothingMs": 200, "shiftScrollsHorizontally": false,
                      "horizontalSpeed": 1.5, "enabled": false},
     "scrollWheel": {"inverted": true, "mode": "freespin", "smartShiftThreshold": 30},
     "thumbWheel": {"inverted": true, "reversed": true, "action": "tabs", "step": 4, "future": 1},
     "apps": {"com.apple.Safari": {"smoothScroll": {"speed": 3}, "thumbWheel": {"action": "zoom"}}}}
    """#)
    config.restoreScrollingDefaults()
    #expect(config[["smoothScroll"]] == nil && config[["scrollWheel"]] == nil)
    #expect(config[["thumbWheel"]] as? [String: Int] == ["future": 1])
    #expect(config.double(["apps", "com.apple.Safari", "smoothScroll", "speed"]) == 3)
    #expect(config.string(["apps", "com.apple.Safari", "thumbWheel", "action"]) == "zoom")
    var custom = try tree(#"{"thumbWheel": {"left": "volumeDown", "right": "volumeUp"}}"#)
    custom.restoreScrollingDefaults()
    #expect(custom[["thumbWheel"]] == nil)
}

@Test func feelSelectsNoSegmentForCustomValues() throws {
    #expect(ConfigTree().feelSelection == .balanced)
    #expect(try tree(#"{"smoothScroll": {"acceleration": 1.2, "smoothingMs": 350}}"#).feelSelection == .gliding)
    let custom = try tree(#"{"smoothScroll": {"acceleration": 2, "smoothingMs": 350}}"#)
    #expect(custom.feelSelection == nil)
    #expect(Feel.caption(for: nil) == "Custom. Adjust in Advanced.")
    #expect(Feel.caption(for: .balanced) == "How long a scroll glides, and how far fast flicks go.")
    #expect(Feel.presets.count == 3)
}

@Test func accelerationReadsAsAStrength() {
    #expect(Format.strength(0) == "Off")
    #expect(Format.strength(1) == "1.0")
    #expect(Format.strength(2.5) == "2.5")
    #expect(!Format.strength(1.2).contains("×"))
}

// MARK: Control availability

@Test func aControlHidesOnlyOnAnExplicitFalseWithNothingSet() {
    let lacks = [mouse(m750)]
    #expect(ControlAvailability.of([\.smartShift], devices: lacks, configured: false) == .hidden)
    #expect(ControlAvailability.of([\.smartShift], devices: lacks, configured: true) == .unsupportedButConfigured)
    #expect(ControlAvailability.unsupportedButConfigured.caption == "Not supported by this mouse.")
    #expect(ControlAvailability.available.caption == nil)
    // Any one capability suffices.
    #expect(ControlAvailability.of([\.smoothScroll, \.thumbWheel], devices: lacks, configured: false) == .available)
    // Unknown: a nil member, no capabilities yet, or no mouse known.
    #expect(ControlAvailability.of([\.haptics], devices: lacks, configured: false) == .available)
    #expect(ControlAvailability.of([\.smartShift], devices: [mouse(nil)], configured: false) == .available)
    #expect(ControlAvailability.of([\.smartShift], devices: [], configured: false) == .available)
    // Any known mouse that has it.
    #expect(ControlAvailability.of([\.smartShift], devices: [mouse(m750), mouse(mxMaster3S)], configured: false) == .available)
}

@Test func offPausedOfflineOrNoMouseLeavesEveryControlShown() {
    let device = mouse(noWheels)
    #expect(ControlAvailability.devices(primary: device, running: true, paused: false) == [device])
    #expect(ControlAvailability.devices(primary: device, running: false, paused: false).isEmpty)
    #expect(ControlAvailability.devices(primary: device, running: true, paused: true).isEmpty)
    #expect(ControlAvailability.devices(primary: mouse(noWheels, online: false), running: true, paused: false).isEmpty)
    #expect(ControlAvailability.devices(primary: nil, running: true, paused: false).isEmpty)
    let offline = ScrollingLayout(config: ConfigTree(), devices: [])
    #expect(ScrollingLayout.Row.allCases.allSatisfy { offline.availability($0) == .available })
    #expect(offline.smoothScrollingRows == [.smoothScrolling, .feel, .speed])
    #expect(offline.mainWheelRows == [.reverseDirection, .wheelMode, .smartShift])
    #expect(offline.showsThumbWheel)
}

@Test func pointerControlsFollowAdjustableDPI() {
    let noDPI = [mouse(.init(dpi: false))]
    #expect(ControlAvailability.of([\.dpi], devices: noDPI, configured: false) == .hidden)
    #expect(ControlAvailability.of([\.dpi], devices: noDPI, configured: true) == .unsupportedButConfigured)
    #expect(ControlAvailability.of([\.dpi], devices: [mouse(.init(dpi: true))], configured: false) == .available)
}

@Test func aNotchedWheelKeepsReverseDirectionWithoutWheelModeOrSmartShift() {
    let layout = ScrollingLayout(config: ConfigTree(), devices: [mouse(m750)])
    #expect(layout.mainWheelRows == [.reverseDirection])
    #expect(layout.smoothScrollingRows == [.smoothScrolling, .feel, .speed])
    #expect(!layout.showsThumbWheel)
    #expect(!layout.shows(.switchesAt))
    let mx = ScrollingLayout(config: ConfigTree(), devices: [mouse(mxMaster3S)])
    #expect(mx.mainWheelRows == [.reverseDirection, .wheelMode, .smartShift])
    #expect(mx.showsThumbWheel)
}

@Test func aMouseWithNeitherWheelShowsNotSupported() throws {
    let layout = ScrollingLayout(config: ConfigTree(), devices: [mouse(noWheels)])
    #expect(layout.isEmpty)
    #expect(!layout.hasAdvanced)
    // Only the main wheel missing: the switch and Feel still shape the thumb wheel; Speed goes.
    let thumbOnly = ScrollingLayout(config: ConfigTree(),
                                    devices: [mouse(.init(smartShift: false, smoothScroll: false, thumbWheel: true))])
    #expect(thumbOnly.smoothScrollingRows == [.smoothScrolling, .feel])
    #expect(thumbOnly.mainWheelRows.isEmpty)
    #expect(thumbOnly.showsThumbWheel)
    #expect(!thumbOnly.isEmpty)
}

@Test func aSetValueKeepsItsControlWithTheCaption() throws {
    let config = try tree(#"{"smoothScroll": {"speed": 2}, "scrollWheel": {"inverted": true, "mode": "ratchet"}}"#)
    let layout = ScrollingLayout(config: config, devices: [mouse(noWheels)])
    #expect(layout.availability(.speed) == .unsupportedButConfigured)
    #expect(layout.availability(.reverseDirection) == .unsupportedButConfigured)
    #expect(layout.availability(.wheelMode) == .unsupportedButConfigured)
    #expect(layout.availability(.smartShift) == .hidden)
    #expect(layout.mainWheelRows == [.reverseDirection, .wheelMode])
    #expect(!layout.isEmpty)
}

@Test func theAdvancedSheetShowsOnlyRowsThatApply() throws {
    // Scrolling thumb wheel on a 3S: smooth scrolling's tuning, Switches at, Reverse and Speed.
    let mx = ScrollingLayout(config: ConfigTree(), devices: [mouse(mxMaster3S)])
    #expect(mx.advancedSmoothScrollingRows == [.acceleration, .glide, .shiftScrollsSideways])
    #expect(mx.advancedMainWheelRows == [.switchesAt])
    #expect(mx.advancedThumbWheelRows == [.thumbWheel(.reverseScrolling), .thumbWheel(.speed)])
    // Actions: Swap directions and Turn distance instead; SmartShift off hides Switches at.
    let actions = try tree(#"{"thumbWheel": {"action": "tabs"}, "scrollWheel": {"smartShiftThreshold": 255}}"#)
    let tabs = ScrollingLayout(config: actions, devices: [mouse(mxMaster3S)])
    #expect(tabs.advancedThumbWheelRows == [.thumbWheel(.swapDirections), .thumbWheel(.turnDistance)])
    #expect(tabs.advancedMainWheelRows.isEmpty)
    // Actions here but scrolling in an app: Reverse direction too.
    let appScrolls = try tree(#"{"thumbWheel": {"action": "tabs"}, "apps": {"x": {"thumbWheel": {"action": "scroll"}}}}"#)
    #expect(ScrollingLayout(config: appScrolls, devices: []).advancedThumbWheelRows
        == [.thumbWheel(.reverseScrolling), .thumbWheel(.swapDirections), .thumbWheel(.turnDistance)])
    // A notched-wheel mouse: no SmartShift or thumb wheel rows, smooth scrolling's stay.
    let notched = ScrollingLayout(config: ConfigTree(), devices: [mouse(m750)])
    #expect(notched.advancedMainWheelRows.isEmpty && notched.advancedThumbWheelRows.isEmpty)
    #expect(notched.hasAdvanced)
}

@Test func anAppsThumbWheelRowsLeaveOutGlobalOnlyKeys() {
    #expect(ThumbWheelAdvancedRow.rows(scrolls: false, someAppScrolls: true, inApp: true, inherits: false)
        == [.swapDirections, .turnDistance])
    #expect(ThumbWheelAdvancedRow.rows(scrolls: false, someAppScrolls: false, inApp: true, inherits: true) == [.swapDirections])
    #expect(ThumbWheelAdvancedRow.rows(scrolls: true, someAppScrolls: false, inApp: true, inherits: false).isEmpty)
}
