import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// A press the config leaves to the mouse ("Mouse Default": no binding where it is pressed, a
/// binding in some other scope) does what the mouse does without PureMouse, and never holds the
/// pointer unless the press is a gesture.
@MainActor
@Suite struct SessionMouseDefaultTests {
    private func press(_ h: SessionHarness, _ cid: UInt16) async {
        h.fake.emit(0x1B04, params: [UInt8(cid >> 8), UInt8(cid & 0xFF)])
        await h.session.diversion.drain()
        await h.session.deviceActions.drain()
    }

    private func release(_ h: SessionHarness) async {
        h.fake.emit(0x1B04, params: [0, 0])
        await h.session.diversion.drain()
        await h.session.deviceActions.drain()
    }

    // MARK: Native behaviour

    @Test func theNativeBehaviourTableNamesTheControlsTheDaemonCanReproduce() {
        #expect(Config.nativeBehaviour(of: 0x52) == .click(button: 2))
        #expect(Config.nativeBehaviour(of: 0x53) == .click(button: 3))
        #expect(Config.nativeBehaviour(of: 0x56) == .click(button: 4))
        #expect(Config.nativeBehaviour(of: 0xC4) == .action(.toggleScrollMode))
        #expect(Config.nativeBehaviour(of: 0xFD) == .action(.cycleDPI))
        // The gesture button, the thumb panel and every other control have none to give back.
        for cid: UInt16 in [0xC3, 0x1A0, 0x50, 0x51, 0xD7, 0x1000] { #expect(Config.nativeBehaviour(of: cid) == nil) }
        // The daemon's native clicks come from the same table.
        #expect(NativeButton.number(for: 0x52) == 2 && NativeButton.number(for: 0x53) == 3 && NativeButton.number(for: 0x56) == 4)
        #expect(NativeButton.number(for: 0xC4) == nil && NativeButton.number(for: 0xFD) == nil)
    }

    @Test func mouseDefaultOnTheModeShiftButtonSwitchesTheWheelMode() async throws {
        // Bound only in an app, so pressed here (no such app in front) it is the mouse's own.
        let config = try SessionHarness.config(#"{"apps": {"com.example.x": {"buttons": {"top": "mute"}}}}"#)
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.control(0xC4)?.diverted == true)
        let before = h.fake.requests(feature: 0x2110, function: 1).count
        await press(h, 0xC4)
        await release(h)
        #expect(h.session.state.scrollMode != nil)
        #expect(h.fake.requests(feature: 0x2110, function: 1).count > before)
    }

    @Test func mouseDefaultOnTheDPIButtonCyclesThePointerSpeed() async throws {
        let config = try SessionHarness.config(
            #"{"dpi": 800, "dpiPresets": [800, 1600], "apps": {"com.example.x": {"buttons": {"0x00fd": "mute"}}}}"#)
        let h = try await SessionHarness(.m750, config: config)
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.control(0xFD)?.diverted == true && h.fake.dpi == 800)
        await press(h, 0xFD)
        await release(h)
        #expect(h.fake.dpi == 1600)
    }

    @Test func aControlWithNoNativeBehaviourDoesNothingWhenLeftToTheMouse() async throws {
        let config = try SessionHarness.config(#"{"apps": {"com.example.x": {"buttons": {"gesture": "mute"}}}}"#)
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        h.fake.transport.sent.removeAll()
        await press(h, 0xC3)
        await release(h)
        #expect(h.session.held.native.isEmpty)
        #expect(h.fake.requests(feature: 0x2110, function: 1).isEmpty && h.fake.requests(feature: 0x2201, function: 3).isEmpty)
    }

    // MARK: The pointer

    @Test func aPressThatIsNotAGestureDoesNotHoldThePointer() async throws {
        // A gesture in an app, a plain action everywhere else: the control is diverted with raw
        // pointer motion for the app's sake, which must be off while the other press is held.
        let config = try SessionHarness.config("""
            {"buttons": {"gesture": "mute"},
             "apps": {"com.example.x": {"buttons": {"gesture": {"click": "none", "up": "volumeUp"}}}}}
            """)
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.control(0xC3)?.diverted == true && h.fake.control(0xC3)?.rawXY == true)
        await press(h, 0xC3)
        #expect(h.fake.control(0xC3)?.diverted == true && h.fake.control(0xC3)?.rawXY == false)
        await release(h)
        #expect(h.fake.control(0xC3)?.diverted == true && h.fake.control(0xC3)?.rawXY == true)
        #expect(h.session.pointerFree.isEmpty)
    }

    @Test func aPressThatIsAGestureStillHoldsThePointer() async throws {
        let config = try SessionHarness.config(#"{"buttons": {"gesture": {"click": "none", "up": "volumeUp"}}}"#)
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        h.fake.transport.sent.removeAll()
        await press(h, 0xC3)
        #expect(h.fake.control(0xC3)?.rawXY == true && h.fake.controlWrites(cid: 0xC3).isEmpty)
        await release(h)
        #expect(h.fake.controlWrites(cid: 0xC3).isEmpty)
    }

    @Test func aDroppedPressForgetsThatThePointerWasFree() async throws {
        let config = try SessionHarness.config("""
            {"buttons": {"gesture": "mute"},
             "apps": {"com.example.x": {"buttons": {"gesture": {"click": "none", "up": "volumeUp"}}}}}
            """)
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        await press(h, 0xC3)
        #expect(h.session.pointerFree == [0xC3])
        h.session.dropHeld()
        #expect(h.session.pointerFree.isEmpty)
        // The apply that follows a reconnect sets the control's reporting again.
        try await h.session.apply()
        #expect(h.fake.control(0xC3)?.rawXY == true)
    }
}
