import Foundation
import Testing
@testable import PureMouseKit

@Suite struct ThumbWheelConfigTests {
    func thumb(_ json: String) throws -> Config.ThumbWheel {
        try #require(try JSONDecoder().decode(Config.self, from: Data(#"{"thumbWheel": \#(json)}"#.utf8)).thumbWheel)
    }

    @Test func scrollsByDefault() throws {
        let t = try thumb(#"{"inverted": true}"#)
        #expect(t.mode == .scroll && t.inverted == true)
        #expect(Config.empty.global.thumbWheel.mode == .scroll)
    }

    @Test func presetsAreActionPairsWithTheirStep() throws {
        #expect(try thumb(#"{"action": "volume"}"#).mode == .actions(left: .volumeDown, right: .volumeUp))
        #expect(try thumb(#"{"action": "volume"}"#).step == 2)
        #expect(try thumb(#"{"action": "zoom"}"#).mode == .actions(left: .zoomOut, right: .zoomIn))
        #expect(try thumb(#"{"action": "tabs"}"#).mode == .actions(left: .previousTab, right: .nextTab))
        let spaces = try thumb(#"{"action": "spaces", "step": 6}"#)
        #expect(spaces.mode == .actions(left: .spaceLeft, right: .spaceRight) && spaces.step == 6)
        #expect(try thumb(#"{"action": "scroll"}"#).mode == .scroll)
    }

    @Test func leftAndRightReplaceOneDirectionEach() throws {
        let t = try thumb(#"{"action": "volume", "left": {"keys": "cmd+["}, "right": "missionControl"}"#)
        guard case .actions(.keys(let k), .missionControl) = t.mode else { Issue.record("\(t.mode)"); return }
        #expect(k.key == 33 && t.step == 2)
        #expect(try thumb(#"{"action": "volume", "left": "mute"}"#).mode == .actions(left: .mute, right: .volumeUp))
        #expect(try thumb(#"{"right": "mute"}"#).mode == .actions(left: .none, right: .mute))
        #expect(try thumb(#"{"right": "mute"}"#).step == Config.ThumbWheel.defaultStep)
    }

    @Test(arguments: [
        #"{"action": "explode"}"#, #"{"action": "missionControl"}"#, #"{"step": 0}"#, #"{"step": 37}"#,
        #"{"left": "explode"}"#,
    ])
    func badThumbWheelSettingsAreErrors(json: String) {
        #expect(throws: DecodingError.self) { try thumb(json) }
    }

    @Test func unknownPresetNamesTheChoices() {
        do {
            _ = try thumb(#"{"action": "explode"}"#)
            Issue.record("accepted")
        } catch {
            #expect(ConfigCheck.message(for: error).hasPrefix(
                "thumbWheel.action: unknown thumb wheel action 'explode'; known: scroll, spaces, tabs, volume, zoom"))
        }
    }

    @Test func newActionsHaveNames() {
        for name in ["volumeUp", "volumeDown", "mute", "brightnessUp", "brightnessDown", "nextTab", "previousTab",
                     "zoomIn", "zoomOut"] {
            #expect(Action.named[name] != nil, "\(name)")
        }
    }
}

@Suite struct AppConfigTests {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    static let base = """
        "buttons": {"back": "navigateBack", "middle": "missionControl",
                    "gesture": {"click": "missionControl", "left": "spaceLeft", "right": "spaceRight"}},
        "thumbWheel": {"inverted": true, "action": "volume", "step": 4},
        "smoothScroll": {"speed": 2, "smoothingMs": 300}
        """

    @Test func noAppsMeansNoLookup() throws {
        let config = try decode("{\(Self.base)}")
        #expect(config.apps.isEmpty && config.settings(forApp: "com.apple.Safari") == nil)
        #expect(config.boundControls == [0x53, 0x52, 0xC3])
    }

    @Test func buttonsOverrideOnlyWhatTheyName() throws {
        let config = try decode("""
            {\(Self.base), "apps": {"com.apple.Safari": {"buttons": {"back": {"keys": "cmd+["}, "top": "showDesktop"}}}}
            """)
        let safari = try #require(config.settings(forApp: "com.apple.Safari"))
        guard case .action(.keys) = safari.bindings[0x53] else { Issue.record("back"); return }
        guard case .action(.missionControl) = safari.bindings[0x52] else { Issue.record("middle kept"); return }
        guard case .action(.showDesktop) = safari.bindings[0xC4] else { Issue.record("top added"); return }
        #expect(safari.setsButtons && !safari.setsThumbWheel && !safari.setsSmoothScroll)
        #expect(safari.buttons == [0x53, 0xC4])  // only these need the frontmost app at a press
        // The rest is the global settings.
        #expect(safari.thumbWheel.mode == .actions(left: .volumeDown, right: .volumeUp) && safari.smoothScroll?.speed == 2)
        // Global bindings are untouched; the app's extra button is diverted everywhere.
        #expect(config.bindings[0xC4] == nil && config.boundControls.contains(0xC4))
    }

    @Test func gestureDirectionsMergeOntoTheGlobalGesture() throws {
        let config = try decode("""
            {\(Self.base), "apps": {"com.apple.Safari": {"buttons": {"gesture": {"left": "navigateBack"}}}}}
            """)
        guard case .gesture(let g) = config.settings(forApp: "com.apple.Safari")?.bindings[0xC3] else {
            Issue.record("gesture"); return
        }
        #expect(g.left == .navigateBack && g.right == .spaceRight && g.click == .missionControl && g.up == .none)
        // Over an action binding, a gesture starts from nothing.
        let other = try decode(#"{"buttons": {"gesture": "launchpad"}, "apps": {"x": {"buttons": {"gesture": {"up": "appExpose"}}}}}"#)
        guard case .gesture(let fresh) = other.settings(forApp: "x")?.bindings[0xC3] else { Issue.record("fresh"); return }
        #expect(fresh.up == .appExpose && fresh.click == .none)
    }

    @Test func thumbWheelAndSmoothScrollMergeKeyByKey() throws {
        let config = try decode("""
            {\(Self.base), "apps": {
              "com.google.Chrome": {"thumbWheel": {"action": "tabs"}, "smoothScroll": {"speed": 3}},
              "com.apple.Music": {"thumbWheel": {"step": 1}},
              "com.apple.Preview": {"thumbWheel": {"action": "scroll"}, "smoothScroll": {"enabled": false}}}}
            """)
        let chrome = try #require(config.settings(forApp: "com.google.Chrome"))
        #expect(chrome.thumbWheel.mode == .actions(left: .previousTab, right: .nextTab) && chrome.thumbWheel.step == 3)
        #expect(chrome.smoothScroll?.speed == 3 && chrome.smoothScroll?.smoothingMs == 300 && chrome.setsSmoothScroll)
        let music = try #require(config.settings(forApp: "com.apple.Music"))
        #expect(music.thumbWheel.mode == .actions(left: .volumeDown, right: .volumeUp) && music.thumbWheel.step == 1)
        let preview = try #require(config.settings(forApp: "com.apple.Preview"))
        #expect(preview.thumbWheel.mode == .scroll && preview.smoothScroll?.enabled == false && preview.smoothScroll?.speed == 2)
    }

    @Test func partialThumbWheelInAnAppKeepsTheRest() throws {
        let config = try decode("""
            {"thumbWheel": {"left": "volumeDown", "right": "volumeUp", "step": 8}, "apps": {
              "a": {"thumbWheel": {"left": "mute"}},
              "b": {"thumbWheel": {"action": "volume"}},
              "c": {"thumbWheel": {"action": "zoom"}},
              "d": {"thumbWheel": {"action": "zoom", "right": "mute", "step": 5}}}}
            """)
        let a = try #require(config.settings(forApp: "a")).thumbWheel
        #expect(a.mode == .actions(left: .mute, right: .volumeUp) && a.step == 8)
        // The same pair keeps the global step; a different one brings its own.
        let b = try #require(config.settings(forApp: "b")).thumbWheel
        #expect(b.mode == .actions(left: .volumeDown, right: .volumeUp) && b.step == 8)
        let c = try #require(config.settings(forApp: "c")).thumbWheel
        #expect(c.mode == .actions(left: .zoomOut, right: .zoomIn) && c.step == 3)
        let d = try #require(config.settings(forApp: "d")).thumbWheel
        #expect(d.mode == .actions(left: .zoomOut, right: .mute) && d.step == 5)
    }

    @Test func smoothScrollInAnAppWorksWithoutAGlobalOne() throws {
        let config = try decode(#"{"apps": {"com.apple.Safari": {"smoothScroll": {}}}}"#)
        #expect(config.smoothScroll == nil)
        #expect(config.settings(forApp: "com.apple.Safari")?.smoothScroll?.enabled == true)
    }

    @Test func bundleIDsMatchWithoutCase() throws {
        let config = try decode(#"{"apps": {"com.Apple.Safari": {"buttons": {"back": "none"}}}}"#)
        #expect(config.settings(forApp: "com.apple.safari") != nil && config.settings(forApp: "COM.APPLE.SAFARI") != nil)
        #expect(config.settings(forApp: "com.apple.Finder") == nil)
    }

    @Test func globalOnlyKeysInAnAppAreWarnings() throws {
        let config = try decode("""
            {"apps": {"com.apple.Safari": {"dpi": 800, "thumbWheel": {"inverted": true}, "buttons": {"zz": "none"}}}}
            """)
        #expect(config.warnings == [
            "apps.com.apple.Safari.dpi is not a per-app setting; ignored",
            "apps.com.apple.Safari.buttons: unknown button 'zz'",
            "apps.com.apple.Safari.thumbWheel.inverted is global only; ignored",
        ])
        #expect(config.settings(forApp: "com.apple.Safari")?.thumbWheel.inverted == nil)
    }

    @Test(arguments: [
        #"{"apps": {"a": {"smoothScroll": {"speed": 0}}}}"#,
        #"{"apps": {"a": {"thumbWheel": {"step": 99}}}}"#,
        #"{"apps": {"a": {"buttons": {"back": "explode"}}}}"#,
        #"{"apps": {"a": "nope"}}"#,
        #"{"apps": []}"#,
    ])
    func badAppSettingsFailTheLoad(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test func appErrorsNameTheApp() {
        do {
            _ = try decode(#"{"apps": {"com.apple.Safari": {"smoothScroll": {"speed": 0}}}}"#)
            Issue.record("accepted")
        } catch {
            #expect(ConfigCheck.message(for: error).hasPrefix("apps.com.apple.Safari.smoothScroll.speed must be 0.1–10.0"))
        }
        do {
            _ = try decode(#"{"apps": {"com.apple.Safari": {"buttons": {"back": "explode"}}}}"#)
            Issue.record("accepted")
        } catch {
            #expect(ConfigCheck.message(for: error).hasPrefix("apps.com.apple.Safari.buttons.back: unknown action 'explode'"))
        }
    }
}
