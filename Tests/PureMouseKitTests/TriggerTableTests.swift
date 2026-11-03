import Foundation
import Testing
@testable import PureMouseKit

/// A binding as a trigger table (ADR 24, #158): `click`, `doubleClick`, and one hold form, each
/// inheriting on its own from a wider table, with `holdMs` and `doubleClickMs` beside them.
@Suite struct TriggerTableTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func message(_ json: String) -> String? {
        do {
            try ConfigCheck.validate(Data(json.utf8))
            return nil
        } catch {
            return ConfigCheck.message(for: error)
        }
    }

    private func table(_ binding: Config.Binding?) -> Config.Binding.Gesture? {
        if case .gesture(let table)? = binding { table } else { nil }
    }

    private static let forward: UInt16 = 0x0056
    private static let device = "m0123456789ab"

    @Test func aTableDecodesAtTheTopLevelOnAMouseAndInAnApp() throws {
        let json = """
            {"buttons": {"forward": {"click": "navigateForward", "doubleClick": "missionControl", "hold": "precisePointer"}},
             "devices": {"\(Self.device)": {"buttons": {"forward": {"hold": {"precisePointer": 400}}}}},
             "apps": {"com.example.x": {"buttons": {"forward": {"doubleClick": "appExpose"}}}}}
            """
        let config = try decode(json)
        let top = try #require(table(config.bindings[Self.forward]))
        #expect(top.click == .navigateForward && top.doubleClick == .missionControl && top.hold == .precisePointer(dpi: nil))
        let mouse = try #require(table(config.forDevice(Self.device).bindings[Self.forward]))
        #expect(mouse.click == .navigateForward && mouse.doubleClick == .missionControl && mouse.hold == .precisePointer(dpi: 400))
        let app = try #require(table(config.settings(forApp: "com.example.x")?.bindings[Self.forward]))
        #expect(app.click == .navigateForward && app.doubleClick == .appExpose && app.hold == .precisePointer(dpi: nil))
        // On the mouse, the app's table lies over the mouse's: its hold is the mouse's.
        let appOnMouse = try #require(table(config.forDevice(Self.device).settings(forApp: "com.example.x")?.bindings[Self.forward]))
        #expect(appOnMouse.hold == .precisePointer(dpi: 400) && appOnMouse.doubleClick == .appExpose)
        #expect(message(json) == nil)
    }

    @Test func anAppThatSetsOnlyDoubleClickKeepsTheMousesClickAndHold() throws {
        let config = try decode("""
            {"devices": {"\(Self.device)": {"buttons": {"forward": {"click": "navigateForward", "hold": "missionControl"}}}},
             "apps": {"com.example.x": {"buttons": {"forward": {"doubleClick": "appExpose"}}}}}
            """).forDevice(Self.device)
        let app = try #require(table(config.settings(forApp: "com.example.x")?.bindings[Self.forward]))
        #expect(app == {
            var t = Config.Binding.Gesture()
            t.click = .navigateForward
            t.doubleClick = .appExpose
            t.hold = .missionControl
            return t
        }())
    }

    @Test func noneTurnsOneTriggerOffAndABareActionReplacesTheWholeBinding() throws {
        let config = try decode("""
            {"buttons": {"forward": {"click": "navigateForward", "doubleClick": "missionControl", "hold": "appExpose"}},
             "apps": {"com.example.off": {"buttons": {"forward": {"hold": "none", "doubleClick": "none"}}},
                      "com.example.bare": {"buttons": {"forward": "launchpad"}}}}
            """)
        let off = try #require(table(config.settings(forApp: "com.example.off")?.bindings[Self.forward]))
        #expect(off.click == .navigateForward && off.doubleClick == .none && off.hold == .none)
        guard case .action(.launchpad)? = config.settings(forApp: "com.example.bare")?.bindings[Self.forward] else {
            Issue.record("a bare action replaces the table")
            return
        }
    }

    @Test func oneHoldFormReplacesTheOther() throws {
        let config = try decode("""
            {"buttons": {"gesture": {"click": "missionControl", "up": "missionControl", "down": "appExpose"},
                         "back": {"click": "navigateBack", "hold": "launchpad"}},
             "apps": {"com.example.x": {"buttons": {"gesture": {"hold": "showDesktop"}, "back": {"left": "spaceLeft"}}}}}
            """)
        let app = try #require(config.settings(forApp: "com.example.x"))
        let gesture = try #require(table(app.bindings[0x00C3]))
        #expect(gesture.click == .missionControl && gesture.hold == .showDesktop && !gesture.moves)
        let back = try #require(table(app.bindings[0x0053]))
        #expect(back.click == .navigateBack && back.hold == .none && back.left == .spaceLeft)
    }

    @Test func errorsNameTheField() {
        #expect(message(#"{"buttons": {"back": {"hold": "explode"}}}"#) == "buttons.back.hold: unknown action “explode”")
        #expect(message(#"{"buttons": {"back": {"hold": "launchpad", "up": "missionControl"}}}"#)?
            .hasPrefix("buttons.back.hold: ") == true)
        #expect(message(#"{"apps": {"x": {"buttons": {"back": {"hold": "launchpad", "left": "spaceLeft"}}}}}"#)?
            .hasPrefix("apps.x.buttons.back.hold: ") == true)
        #expect(message(#"{"buttons": {"back": {"click": "navigateBack", "scroll": "volume"}}}"#)?
            .hasPrefix("buttons.back.scroll: ") == true)
        #expect(message(#"{"buttons": {"back": {"click": "navigateBack", "tripleClick": "mute"}}}"#)?
            .hasPrefix("buttons.back.tripleClick: unknown trigger") == true)
        #expect(message(#"{"buttons": {"back": {"doubleClick": "precisePointer"}}}"#)?
            .hasPrefix("buttons.back.doubleClick: precisePointer works only") == true)
        #expect(message(#"{"buttons": {"gesture": {"up": "precisePointer"}}}"#)?.hasPrefix("buttons.gesture.up: ") == true)
        #expect(message(#"{"thumbWheel": {"left": "precisePointer"}}"#)?.hasPrefix("thumbWheel.left: ") == true)
        #expect(message(#"{"buttons": {"back": {"precisePointer": 10}}}"#) == "buttons.back.precisePointer must be 50–25600, not 10")
    }

    @Test func holdAndDoubleClickDelaysAreRanged() throws {
        #expect(message(#"{"holdMs": 149}"#) == "holdMs must be 150–1000, not 149")
        #expect(message(#"{"holdMs": 1001}"#) == "holdMs must be 150–1000, not 1001")
        #expect(message(#"{"doubleClickMs": 100}"#) == "doubleClickMs must be 150–1000, not 100")
        #expect(message(#"{"doubleClickMs": 2000}"#) == "doubleClickMs must be 150–1000, not 2000")
        let config = try decode(#"{"holdMs": 150, "doubleClickMs": 1000}"#)
        #expect(config.holdMs == 150 && config.doubleClickMs == 1000)
        let fresh = try decode("{}")
        #expect(fresh.holdMs == 350 && fresh.doubleClickMs == nil)
    }

    @Test func theDoubleClickIntervalIsTheConfiguredOneElseTheSystemsWithinRange() throws {
        let fresh = try decode("{}")
        #expect(fresh.doubleClickInterval(systemSeconds: nil) == 500)
        #expect(fresh.doubleClickInterval(systemSeconds: 0.3) == 300)
        #expect(fresh.doubleClickInterval(systemSeconds: 5) == 1000)
        #expect(fresh.doubleClickInterval(systemSeconds: 0.05) == 150)
        #expect(fresh.doubleClickInterval(systemSeconds: -1) == 500)
        #expect(try decode(#"{"doubleClickMs": 250}"#).doubleClickInterval(systemSeconds: 0.8) == 250)
    }

    @Test func theNewActionsHaveNamesAndAnObjectForm() throws {
        #expect(Action.named["precisePointer"] == .precisePointer(dpi: nil))
        #expect(Action.named["dragLock"] == .dragLock)
        let config = try decode(#"{"buttons": {"top": "dragLock", "back": {"precisePointer": 800}}}"#)
        guard case .action(.dragLock)? = config.bindings[0x00C4],
              case .action(.precisePointer(dpi: 800))? = config.bindings[0x0053] else {
            Issue.record("bare new actions decode")
            return
        }
        #expect(Action.precisePointer(dpi: nil).isWhileHeld && !Action.dragLock.isWhileHeld)
    }

    @Test func aTableOnAPrimaryClickIsDroppedWithTheWarning() throws {
        let config = try decode(#"{"buttons": {"0x0050": {"click": "mute", "hold": "launchpad"}}}"#)
        #expect(config.bindings[0x0050] == nil)
        #expect(config.warnings == ["buttons.0x0050: the left and right buttons always click; ignored"])
    }
}
