import CoreGraphics
import Foundation
import Testing
@testable import PureMouseKit

@Suite struct ConfigTests {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func exampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../config.example.json").standardized
        // The example mirrors the live config, so check its shape rather than particular values.
        let config = try Config.load(from: url)
        #expect(config.dpi != nil && config.smoothScroll != nil)
        #expect(config.bindings.count == config.buttons.count)  // every button name resolves
        #expect(config.bindings.values.contains { if case .gesture = $0 { true } else { false } })
    }

    @Test func emptyConfigIsValid() throws {
        let config = try decode("{}")
        #expect(config.buttons.isEmpty && config.dpi == nil && config.gesture.distanceMm == 4)
    }

    @Test func actionObjectsAndHexButtons() throws {
        let config = try decode(#"{"buttons": {"0x00c4": {"keys": "cmd+shift+4"}, "back": {"run": "true"}}}"#)
        let b = config.bindings
        guard case .action(.keys(let k)) = b[0x00C4] else { Issue.record("keys"); return }
        #expect(k.key == 21 && k.modifiers == [.maskCommand, .maskShift])
        guard case .action(.run("true")) = b[0x0053] else { Issue.record("run"); return }
    }

    @Test func unknownActionIsAnError() {
        #expect(throws: DecodingError.self) { try decode(#"{"buttons": {"top": "explode"}}"#) }
    }

    @Test func hapticActionAndThumbPanelDecode() throws {
        let config = try decode(#"{"buttons": {"thumbPanel": {"haptic": "sharpStateChange"}}}"#)
        #expect(config.unknownButtons.isEmpty)
        guard case .action(let action) = config.bindings[0x01A0] else { Issue.record("haptic"); return }
        #expect(action == .haptic(.sharpStateChange) && action.actsOnDevice)
        #expect(Config.Button(cid: 0x01A0) == .thumbPanel)
    }

    @Test func allHapticWaveformsDecodeAndUnknownOnesFail() throws {
        for waveform in HapticWaveform.allCases {
            let action = try JSONDecoder().decode(Action.self, from: Data("{\"haptic\":\"\(waveform.rawValue)\"}".utf8))
            #expect(action == .haptic(waveform) && action.actsOnDevice)
        }
        #expect(HapticWaveform.allCases.map(\.id) == Array(UInt8(0)...14) + [0x1B])
        #expect(throws: DecodingError.self) { try decode(#"{"buttons": {"top": {"haptic": "unknown"}}}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"buttons": {"top": {"haptic": 27}}}"#) }
        let gesture = try decode(#"{"buttons": {"thumbPanel": {"click": {"haptic": "completed"}}}}"#)
        guard case .gesture(let binding) = gesture.bindings[0x01A0] else { Issue.record("gesture"); return }
        #expect(binding.click == .haptic(.completed))
    }

    @Test func partialGestureDefaultsToNone() throws {
        let b = try decode(#"{"buttons": {"gesture": {"up": "missionControl"}}}"#).bindings
        guard case .gesture(let g) = b[0x00C3] else { Issue.record("gesture"); return }
        #expect(g.up == .missionControl && g.click == Action.none)
    }

    @Test(arguments: [
        #"{"dpi": 0}"#, #"{"dpi": 100000}"#,
        #"{"scrollWheel": {"smartShiftThreshold": 0}}"#,
        #"{"smoothScroll": {"speed": 1e300}}"#, #"{"smoothScroll": {"speed": 0}}"#,
        #"{"smoothScroll": {"horizontalSpeed": -1}}"#, #"{"smoothScroll": {"acceleration": -1}}"#,
        #"{"smoothScroll": {"smoothingMs": 1e300}}"#, #"{"smoothScroll": {"smoothingMs": -5}}"#,
        #"{"gesture": {"distanceMm": 1e20}}"#, #"{"gesture": {"distanceMm": 0}}"#,
        #"{"gesture": {"repeatIntervalMs": -1}}"#, #"{"gesture": {"repeatIntervalMs": 9223372036854775807}}"#,
        #"{"dpiPresets": [800, 10]}"#, #"{"dpiPresets": [100000]}"#,
        #"{"dpiPresets": [400, 800, 1200, 1600, 2000, 2400, 2800, 3200, 3600]}"#,
    ])
    func outOfRangeNumbersAreErrors(json: String) {
        // Accepting these would overflow later (converting to Int or Duration) and crash-loop.
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test func rangeErrorNamesTheField() {
        do {
            _ = try decode(#"{"smoothScroll": {"speed": 1e300}}"#)
            Issue.record("accepted")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription.hasPrefix("smoothScroll.speed must be 0.1–10.0"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func boundaryNumbersAreAccepted() throws {
        let low = try decode("""
            {"dpi": 50, "scrollWheel": {"smartShiftThreshold": 1},
             "smoothScroll": {"speed": 0.1, "horizontalSpeed": 0.1, "acceleration": 0, "smoothingMs": 0},
             "gesture": {"distanceMm": 0.5, "repeatIntervalMs": 0}}
            """)
        #expect(low.dpi == 50 && low.smoothScroll?.smoothingMs == 0 && low.gesture.distanceMm == 0.5)
        let high = try decode("""
            {"dpi": 25600, "scrollWheel": {"smartShiftThreshold": 255},
             "smoothScroll": {"speed": 10, "horizontalSpeed": 10, "acceleration": 10, "smoothingMs": 2000},
             "gesture": {"distanceMm": 50, "repeatIntervalMs": 5000}}
            """)
        #expect(high.dpi == 25600 && high.scrollWheel?.smartShiftThreshold == 255 && high.gesture.repeatIntervalMs == 5000)
    }

    @Test func smoothScrollCanBeDisabledKeepingItsTuning() throws {
        #expect(try decode(#"{"smoothScroll": {}}"#).smoothScroll?.enabled == true)
        let off = try #require(try decode(#"{"smoothScroll": {"enabled": false, "speed": 2}}"#).smoothScroll)
        #expect(!off.enabled && off.speed == 2)
    }

    @Test func dpiPresetsAndCycleDPI() throws {
        let config = try decode(#"{"dpiPresets": [800, 1600, 3200], "buttons": {"top": "cycleDPI"}}"#)
        #expect(config.dpiPresets == [800, 1600, 3200] && Action.named["cycleDPI"] == .cycleDPI)
        guard case .action(.cycleDPI) = config.bindings[0xC4] else { Issue.record("cycleDPI"); return }
        #expect(try decode(#"{"dpiPresets": []}"#).dpiPresets.isEmpty)
        do {
            _ = try decode(#"{"dpiPresets": [800, 10]}"#)
            Issue.record("accepted")
        } catch {
            #expect(ConfigCheck.message(for: error) == "dpiPresets[1] must be 50–25600, not 10")
        }
    }

    @Test func keystrokeParsing() {
        #expect(Keystroke("ctrl+left") == Keystroke(key: 123, modifiers: .maskControl))
        #expect(Keystroke("f11")?.key == 103)
        #expect(Keystroke("cmd+nope") == nil)
        #expect(Keystroke("a+b") == nil)
    }
}

@Suite struct ConfigKitTests {
    @Test func unknownButtonsAreCollectedNotFatal() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"buttons": {"zz": "none", "back": "none"}}"#.utf8))
        #expect(config.unknownButtons == ["zz"] && config.bindings.keys.sorted() == [0x53])
    }

    @Test func configCheckUsesTheRealDecoder() {
        #expect(throws: DecodingError.self) { try ConfigCheck.validate(Data(#"{"dpi": 0}"#.utf8)) }
        #expect(throws: Never.self) { try ConfigCheck.validate(Data(#"{"dpi": 1600}"#.utf8)) }
    }

    @Test func buttonNamesByControlID() {
        #expect(Config.Button(cid: 0x53) == .back && Config.Button(cid: 0xC3) == .gesture && Config.Button(cid: 0x99) == nil)
    }

    @Test func arrowKeysCarryKeyboardFlags() throws {
        let flags = try #require(Keystroke("ctrl+left")).eventFlags
        #expect(flags.contains([.maskControl, .maskSecondaryFn, .maskNumericPad]))
        #expect(try #require(Keystroke("cmd+a")).eventFlags == .maskCommand)
    }
}

@Suite struct ConfigMessageTests {
    func message(_ json: String) -> String {
        do {
            try ConfigCheck.validate(Data(json.utf8))
            return "accepted"
        } catch {
            return ConfigCheck.message(for: error)
        }
    }

    @Test func namesTheField() {
        #expect(message(#"{"smoothScroll": {"speed": 1e300}}"#).hasPrefix("smoothScroll.speed must be 0.1–10.0"))
        #expect(message(#"{"buttons": {"top": "explode"}}"#).hasPrefix("buttons.top: unknown action 'explode'"))
        #expect(message(#"{"dpi": "high"}"#) == "dpi: expected a whole number")
    }

    @Test func syntaxErrorsSayWhere() {
        #expect(message(#"{"dpi": 1600"#).contains("not valid JSON"))
    }
}
