import Foundation
import Testing
@testable import mxd

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

    @Test func partialGestureDefaultsToNone() throws {
        let b = try decode(#"{"buttons": {"gesture": {"up": "missionControl"}}}"#).bindings
        guard case .gesture(let g) = b[0x00C3] else { Issue.record("gesture"); return }
        #expect(g.up == .missionControl && g.click == Action.none)
    }

    @Test func keystrokeParsing() {
        #expect(Keystroke("ctrl+left") == Keystroke(key: 123, modifiers: .maskControl))
        #expect(Keystroke("f11")?.key == 103)
        #expect(Keystroke("cmd+nope") == nil)
        #expect(Keystroke("a+b") == nil)
    }
}
