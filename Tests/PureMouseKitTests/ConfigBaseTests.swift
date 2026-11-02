import Foundation
import Testing
@testable import PureMouseKit

@Suite struct ConfigBaseTests {
    func decode(_ json: String, on base: Config?) throws -> Config {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        struct Layer: Decodable {
            let config: Config
            init(from decoder: Decoder) throws {
                config = try Config(decoder.container(keyedBy: AnyKey.self), base: decoder.userInfo[.base] as? Config)
            }
        }
        decoder.userInfo[.base] = base
        return try decoder.decode(Layer.self, from: data).config
    }

    static let base = """
        {"dpi": 1600, "dpiPresets": [800, 1600],
         "scrollWheel": {"inverted": true, "smartShiftThreshold": 20},
         "thumbWheel": {"inverted": true, "action": "volume", "step": 4},
         "smoothScroll": {"speed": 2, "smoothingMs": 300},
         "buttons": {"back": "navigateBack", "gesture": {"click": "missionControl", "left": "spaceLeft"}, "zz": "none"},
         "gesture": {"distanceMm": 8}, "universalControl": {"handOff": false}}
        """

    @Test func absentSectionsKeepTheBase() throws {
        let base = try decode(Self.base, on: nil)
        let layered = try decode("{}", on: base)
        #expect(layered.dpi == 1600 && layered.dpiPresets == [800, 1600] && layered.scrollWheel?.smartShiftThreshold == 20)
        #expect(layered.thumbWheel?.step == 4 && layered.smoothScroll?.speed == 2 && layered.gesture.distanceMm == 8)
        #expect(!layered.universalControl.handOff && layered.buttons.count == 3 && layered.unknownButtons.isEmpty)
    }

    @Test func presentKeysLayerOnTheBase() throws {
        let base = try decode(Self.base, on: nil)
        let layered = try decode("""
            {"dpi": 800, "dpiPresets": [400], "scrollWheel": {"mode": "freespin"},
             "thumbWheel": {"reversed": true}, "smoothScroll": {"speed": 3},
             "buttons": {"0x0053": "none", "gesture": {"up": "appExpose"}, "top": "showDesktop", "qq": "none"},
             "gesture": {"repeatIntervalMs": 100}, "universalControl": {}}
            """, on: base)
        #expect(layered.dpi == 800 && layered.dpiPresets == [400])
        #expect(layered.scrollWheel?.mode == .freespin && layered.scrollWheel?.inverted == true
                && layered.scrollWheel?.smartShiftThreshold == 20)
        #expect(layered.thumbWheel?.reversed == true && layered.thumbWheel?.inverted == true && layered.thumbWheel?.step == 4)
        #expect(layered.smoothScroll?.speed == 3 && layered.smoothScroll?.smoothingMs == 300)
        #expect(layered.gesture.distanceMm == 8 && layered.gesture.repeatIntervalMs == 100)
        #expect(!layered.universalControl.handOff)  // present but empty: the base's value
        guard case .action(.none) = layered.bindings[0x53] else { Issue.record("back"); return }
        guard case .gesture(let g) = layered.bindings[0xC3] else { Issue.record("gesture"); return }
        #expect(g.click == .missionControl && g.left == .spaceLeft && g.up == .appExpose)
        #expect(layered.bindings[0xC4] != nil && layered.buttons["back"] == nil && layered.buttons["0x0053"] != nil)
        #expect(layered.unknownButtons == ["qq"])  // the layer's own; the base's are not carried
    }

    @Test func appsAreNotCarriedFromTheBase() throws {
        let base = try decode(#"{"smoothScroll": {"speed": 2}, "apps": {"a.app": {"buttons": {"back": "none"}}}, "buttons": {"zz": "none"}}"#, on: nil)
        #expect(base.apps.count == 1 && base.unknownButtons == ["zz"])
        let layered = try decode(#"{"dpi": 800}"#, on: base)
        #expect(layered.apps.isEmpty && layered.warnings.isEmpty && layered.unknownButtons.isEmpty)
        #expect(layered.smoothScroll?.speed == 2 && layered.buttons.count == 1)
    }

    @Test func appsInTheLayerInheritTheLayeredGlobals() throws {
        let base = try decode(#"{"smoothScroll": {"speed": 2}, "thumbWheel": {"action": "volume"}, "buttons": {"middle": "mute"}}"#, on: nil)
        let layered = try decode("""
            {"smoothScroll": {"smoothingMs": 300}, "buttons": {"back": "navigateBack"},
             "apps": {"x": {"smoothScroll": {"enabled": false}, "buttons": {"forward": "none"}}}}
            """, on: base)
        let app = try #require(layered.settings(forApp: "x"))
        // The base's speed and the layer's smoothing both reach the app, not the defaults.
        #expect(app.smoothScroll?.speed == 2 && app.smoothScroll?.smoothingMs == 300 && app.smoothScroll?.enabled == false)
        #expect(app.thumbWheel.mode == .actions(left: .volumeDown, right: .volumeUp))
        #expect(Set(app.bindings.keys) == [0x52, 0x53, 0x56])
        #expect(layered.warnings.isEmpty)
    }

    @Test func anAppTheBaseAlsoNamesIsNotARepeat() throws {
        let base = try decode(#"{"smoothScroll": {"speed": 2}, "apps": {"x": {"smoothScroll": {"speed": 5}}}}"#, on: nil)
        let layered = try decode(#"{"smoothScroll": {"smoothingMs": 300}, "apps": {"x": {"smoothScroll": {"smoothingMs": 10}}}}"#, on: base)
        #expect(layered.warnings.isEmpty)
        #expect(layered.settings(forApp: "x")?.smoothScroll?.speed == 2)
        #expect(layered.settings(forApp: "x")?.smoothScroll?.smoothingMs == 10)
    }

    @Test func rangeChecksStillApplyOnABase() throws {
        let base = try decode(Self.base, on: nil)
        #expect(throws: DecodingError.self) { try decode(#"{"smoothScroll": {"speed": 0}}"#, on: base) }
        #expect(throws: DecodingError.self) { try decode(#"{"dpiPresets": [10]}"#, on: base) }
    }
}

private extension CodingUserInfoKey {
    static let base = CodingUserInfoKey(rawValue: "base")!
}
