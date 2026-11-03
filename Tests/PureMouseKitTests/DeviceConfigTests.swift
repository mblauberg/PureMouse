import Foundation
import Testing
@testable import PureMouseKit

@Suite struct DeviceConfigTests {
    static let m = "mb03440910000"

    func config(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func action(_ binding: Config.Binding?) -> Action? {
        if case .action(let action) = binding { action } else { nil }
    }

    @Test func aDeviceEntryOverridesTheTopLevelForThatDeviceOnly() throws {
        let c = try config(#"{"dpi": 1600, "devices": {"\#(Self.m)": {"dpi": 1200}}}"#)
        #expect(c.forDevice(Self.m).dpi == 1200)
        #expect(c.forDevice("other").dpi == 1600)
        #expect(c.forDevice(nil).dpi == 1600)
        #expect(c.dpi == 1600)
        #expect(c.warnings.isEmpty)
    }

    @Test func precedenceIsTopLevelThenDeviceThenApp() throws {
        let c = try config(#"""
            {"buttons": {"back": "navigateBack", "forward": "navigateForward"},
             "devices": {"\#(Self.m)": {"buttons": {"back": "missionControl"}}},
             "apps": {"com.example.x": {"buttons": {"forward": "appExpose"}}}}
            """#)
        let device = c.forDevice(Self.m)
        let app = try #require(device.settings(forApp: "com.example.x"))
        #expect(action(app.bindings[0x53]) == .missionControl)
        #expect(action(app.bindings[0x56]) == .appExpose)
        #expect(action(device.global.bindings[0x56]) == .navigateForward)
        // The top level's app scope keeps the top level's back.
        let topApp = try #require(c.settings(forApp: "com.example.x"))
        #expect(action(topApp.bindings[0x53]) == .navigateBack)
    }

    @Test func defaultOnADeviceClearsTheBindingTheTopLevelGivesIt() throws {
        let c = try config(#"""
            {"buttons": {"back": "navigateBack", "0x0056": "navigateForward", "middle": "mute"},
             "devices": {"\#(Self.m)": {"buttons": {"back": "default", "forward": "default"}}}}
            """#)
        let device = c.forDevice(Self.m)
        // Native there: no binding at all, and no name left behind for the control.
        #expect(device.bindings[0x53] == nil && device.bindings[0x56] == nil)
        #expect(action(device.bindings[0x52]) == .mute)
        #expect(device.buttons.keys.sorted() == ["gesture", "middle"])  // the gesture is the default set's
        #expect(device.unknownButtons.isEmpty && c.warnings.isEmpty)
        // The top level and other mice keep the binding.
        #expect(action(c.bindings[0x53]) == .navigateBack)
        #expect(action(c.forDevice("other").bindings[0x53]) == .navigateBack)
        #expect(device.global.bindings[0x53] == nil)
    }

    @Test func defaultOnADeviceHidesAGlobalGestureWhole() throws {
        let c = try config(#"""
            {"buttons": {"gesture": {"click": "missionControl", "left": "spaceLeft"}},
             "devices": {"\#(Self.m)": {"buttons": {"gesture": "default"}}}}
            """#)
        #expect(c.forDevice(Self.m).bindings[0xC3] == nil)
        // A later entry's gesture starts from nothing, not from the cleared one.
        let again = try config(#"""
            {"buttons": {"gesture": {"click": "missionControl", "left": "spaceLeft"}},
             "devices": {"\#(Self.m)": {"buttons": {"gesture": "default"}}},
             "apps": {"com.example.x": {"buttons": {"gesture": {"right": "spaceRight"}}}}}
            """#)
        guard case .gesture(let g) = again.forDevice(Self.m).settings(forApp: "com.example.x")?.bindings[0xC3] else {
            Issue.record("gesture"); return
        }
        #expect(g.right == .spaceRight)
    }

    @Test func defaultAtTheTopLevelRemovesTheDefaultSetsBindingAndNothingElse() throws {
        let withDefault = try config(#"{"buttons": {"back": "default", "0x00c4": "default", "middle": "mute"}}"#)
        // Back is bound by the default set, so Mouse Default there removes it; the top button binds
        // nothing, so the same value there is the same as leaving it out.
        #expect(withDefault.bindings[0x53] == nil && withDefault.bindings[0xC4] == nil)
        #expect(action(withDefault.bindings[0x52]) == .mute && action(withDefault.bindings[0x56]) == .navigateForward)
        #expect(withDefault.buttons.keys.sorted() == ["forward", "gesture", "middle"])
        #expect(withDefault.boundControls == [0x52, 0x56, 0xC3])
        #expect(withDefault.unknownButtons.isEmpty && withDefault.warnings.isEmpty)
        let without = try config(#"{"buttons": {"middle": "mute"}}"#)
        #expect(action(without.bindings[0x53]) == .navigateBack)
    }

    @Test func defaultKeepsTheReservedAndUnknownWarnings() throws {
        let c = try config(#"""
            {"buttons": {"nonsense": "default"},
             "devices": {"\#(Self.m)": {"buttons": {"0x0050": "default", "bogus": "default"}}},
             "apps": {"com.example.x": {"buttons": {"0x0051": "default", "bogus": "default"}}}}
            """#)
        #expect(c.unknownButtons == ["nonsense"])
        #expect(c.warnings.contains { $0.contains("devices.\(Self.m).buttons.0x0050") && $0.contains("always click") })
        #expect(c.warnings.contains { $0.contains("devices.\(Self.m).buttons: unknown button 'bogus'") })
        #expect(c.warnings.contains { $0.contains("apps.com.example.x.buttons.0x0051") })
        #expect(c.warnings.contains { $0.contains("apps.com.example.x.buttons: unknown button 'bogus'") })
        #expect(c.forDevice(Self.m).bindings[0x50] == nil)
    }

    @Test func defaultIsStillNotAnAction() {
        #expect(Action.named["default"] == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Config.self, from: Data(#"{"thumbWheel": {"left": "default"}}"#.utf8))
        }
    }

    @Test func defaultOnAMixedCaseDeviceKeyStillClears() throws {
        let c = try config(#"""
            {"buttons": {"back": "navigateBack"},
             "devices": {"\#(Self.m.uppercased())": {"buttons": {"back": "default"}}}}
            """#)
        #expect(c.forDevice(Self.m).bindings[0x53] == nil)
        #expect(action(c.bindings[0x53]) == .navigateBack)
    }

    @Test func nameOrderDecidesWhenTwoNamesInOneEntryMeetOneControl() throws {
        // "0x0053" sorts before "back": the later name decides, as for any two bindings.
        let c = try config(#"""
            {"buttons": {"back": "mute"},
             "devices": {"\#(Self.m)": {"buttons": {"0x0053": "launchpad", "back": "default"}}}}
            """#)
        let device = c.forDevice(Self.m)
        #expect(device.bindings[0x53] == nil && device.buttons.keys.sorted() == ["forward", "gesture"])
        let reverse = try config(#"""
            {"buttons": {"back": "mute"},
             "devices": {"\#(Self.m)": {"buttons": {"0x0053": "default", "back": "launchpad"}}}}
            """#)
        #expect(action(reverse.forDevice(Self.m).bindings[0x53]) == Action.named["launchpad"])
    }

    @Test func aDeviceSectionAndAnAppSectionMergePerKey() throws {
        let c = try config(#"""
            {"devices": {"\#(Self.m)": {"smoothScroll": {"speed": 2}}},
             "apps": {"com.example.x": {"smoothScroll": {"smoothingMs": 50}}}}
            """#)
        let smooth = try #require(c.forDevice(Self.m).settings(forApp: "com.example.x")?.smoothScroll)
        #expect(smooth.speed == 2 && smooth.smoothingMs == 50)
        #expect(c.settings(forApp: "com.example.x")?.smoothScroll?.speed == 1)
    }

    @Test func entriesMergeAsAppsDoAndPresetsReplaceWhole() throws {
        let c = try config(#"""
            {"dpiPresets": [800, 1600], "thumbWheel": {"action": "tabs", "inverted": true},
             "gesture": {"distanceMm": 6},
             "buttons": {"gesture": {"up": "missionControl", "down": "appExpose"}},
             "devices": {"\#(Self.m)": {"dpiPresets": [1000], "thumbWheel": {"inverted": false},
                                        "gesture": {"repeatIntervalMs": 100},
                                        "buttons": {"gesture": {"up": "launchpad"}}}}}
            """#)
        let d = c.forDevice(Self.m)
        #expect(d.dpiPresets == [1000])
        #expect(d.thumbWheel?.inverted == false && d.thumbWheel?.mode == .actions(left: .previousTab, right: .nextTab))
        #expect(d.gesture.distanceMm == 6 && d.gesture.repeatIntervalMs == 100)
        guard case .gesture(let g) = d.bindings[0x00C3] else { Issue.record("\(String(describing: d.bindings[0xC3]))"); return }
        #expect(g.up == .launchpad && g.down == .appExpose)
    }

    @Test func keysAreLowercasedOnLoad() throws {
        let c = try config(#"{"devices": {"MB03440910000": {"dpi": 1200}, "pB02C": {"dpi": 900}}}"#)
        #expect(c.devices.keys.sorted() == ["mb03440910000", "pb02c"])
        #expect(c.forDevice("mb03440910000").dpi == 1200)
        #expect(c.forDevice("pb02c").dpi == 900)
        #expect(c.warnings.isEmpty)
    }

    @Test func topLevelOnlySectionsInAnEntryAreIgnoredWithAWarning() throws {
        let c = try config(#"""
            {"devices": {"\#(Self.m)": {"apps": {"com.example.x": {"buttons": {"back": "none"}}},
                                        "universalControl": {"handOff": false}, "name": "MX Master 3S"}}}
            """#)
        #expect(c.warnings == [
            "devices.\(Self.m).apps is not a per-device setting; ignored",
            "devices.\(Self.m).universalControl is not a per-device setting; ignored",
        ])
        #expect(c.forDevice(Self.m).apps.isEmpty)
        #expect(c.forDevice(Self.m).universalControl.handOff)
    }

    @Test(arguments: ["m000000000000", "mffffffffffff", "mFFFFFFFFFFFF", "mb0344091000", "mb034409100000",
                      "p12345", "pb02", "x1234", "mb03440910g00", "MX Master 3S", ""])
    func aKeyThatIsNotADeviceKeyMatchesNoDevice(key: String) throws {
        let c = try config(#"{"devices": {"\#(key)": {"dpi": 1200}}}"#)
        #expect(c.warnings == ["devices.\(key): not a device key; it matches no device"])
        #expect(c.devices.isEmpty)
        #expect(c.forDevice(key.lowercased()).dpi == nil)
    }

    @Test func deviceKeysComeFromTheModelIDElseTheProductID() {
        #expect(Config.deviceKey(modelID: [0xB0, 0x34, 0x40, 0x91, 0, 0], productID: 0xB034) == Self.m)
        #expect(Config.deviceKey(modelID: [0, 0, 0, 0, 0, 0], productID: 0xB02C) == "pb02c")
        #expect(Config.deviceKey(modelID: Array(repeating: 0xFF, count: 6), productID: 0xB02C) == "pb02c")
        #expect(Config.deviceKey(modelID: nil, productID: 0xB02C) == "pb02c")
        #expect(Config.deviceKey(modelID: nil, productID: nil) == nil)
        #expect(Config.isDeviceKey(Self.m) && Config.isDeviceKey("pb02c"))
    }

    @Test(arguments: [
        (#"{"dpi": 99999}"#, "devices.mb03440910000.dpi must be"),
        (#"{"smoothScroll": {"speed": 99}}"#, "devices.mb03440910000.smoothScroll.speed must be"),
        (#"{"dpiPresets": [10]}"#, "devices.mb03440910000.dpiPresets:"),
        (#"{"gesture": {"distanceMm": 0}}"#, "devices.mb03440910000.gesture.distanceMm must be"),
    ])
    func anOutOfRangeNumberFailsTheLoadNamingTheEntry(entry: String, prefix: String) {
        let data = Data(#"{"devices": {"\#(Self.m)": \#(entry)}}"#.utf8)
        do {
            try ConfigCheck.validate(data)
            Issue.record("accepted \(entry)")
        } catch {
            #expect(ConfigCheck.message(for: error).hasPrefix(prefix), "\(ConfigCheck.message(for: error))")
        }
    }

    @Test func anInvalidKeyStillFailsTheLoadOnABadValue() {
        #expect(throws: DecodingError.self) { try config(#"{"devices": {"typo": {"dpi": 99999}}}"#) }
    }

    @Test func aPrimaryClickInAnEntryIsDroppedWithTheReservedWarning() throws {
        let c = try config(#"{"devices": {"\#(Self.m)": {"buttons": {"0x0050": "none", "back": "none"}}}}"#)
        let d = c.forDevice(Self.m)
        #expect(d.bindings[0x50] == nil && d.bindings[0x53] != nil)
        #expect(c.warnings == ["devices.\(Self.m).buttons.0x0050: the left and right buttons always click; ignored"])
    }

    @Test func entryProblemsAreReportedOnceAtTheTopLevel() throws {
        let c = try config(#"""
            {"apps": {"com.example.x": {"dpi": 1}},
             "devices": {"\#(Self.m)": {"buttons": {"wheelie": "none"}}, "pb02c": {}}}
            """#)
        #expect(c.warnings == [
            "apps.com.example.x.dpi is not a per-app setting; ignored",
            "devices.\(Self.m).buttons: unknown button 'wheelie'",
        ])
        #expect(c.forDevice(Self.m).warnings.isEmpty && c.forDevice(Self.m).unknownButtons.isEmpty)
        #expect(c.unknownButtons.isEmpty)
    }

    @Test func aRepeatedKeyAfterLowercasingWarnsAndTheLastApplies() throws {
        let c = try config(#"{"devices": {"MB03440910000": {"dpi": 1000}, "\#(Self.m)": {"dpi": 1200}}}"#)
        #expect(c.forDevice(Self.m).dpi == 1200)
        #expect(c.warnings == ["devices.\(Self.m) repeats another entry; the last one applies"])
    }

    @Test func everyScopeCoversDevicesAndTheirApps() throws {
        let c = try config(#"""
            {"buttons": {"back": "none"},
             "devices": {"\#(Self.m)": {"smoothScroll": {}}},
             "apps": {"com.example.x": {"buttons": {"middle": "none"}}}}
            """#)
        // The device's own global scope, the only one with smooth scrolling, and its copy of the app.
        #expect(c.everyScope.contains { $0.smoothScroll != nil })
        #expect(c.everyScope.filter { $0.bindings[0x52] != nil }.count == 2)
        #expect(Config.defaults.everyScope.count == 1)
    }
}
