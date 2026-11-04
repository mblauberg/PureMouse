import HIDPP
import PureMouseKit
import HIDPPTesting
import Testing
@testable import puremouse

/// The M750's notched wheel (0x2130) taken over for smooth scrolling.
@Suite(.quietLog) @MainActor
struct SessionNotchedWheelTests {
    static let smooth = #"{"smoothScroll": {}}"#

    private func wheelWrites(_ fake: FakeDevice) -> [[UInt8]] {
        fake.requests(feature: 0x2130, function: 1).map(\.params).map { Array($0.prefix(1)) }
    }

    @Test func smoothScrollingDivertsTheWheelWithTheTemporaryBitOnlyAndIsReported() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(Self.smooth), identify: true)
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.lowResWheelDiverted)
        #expect(wheelWrites(h.fake) == [[0x01]])  // the reporting bit, nothing persistent
        #expect(h.session.status.capabilities?.smoothScroll == true)
        #expect(h.session.wheelsMayBeDiverted)
    }

    @Test func oneNotchGlidesInWholePixelsToThePerNotchDistance() async throws {
        let recorder = ScrollRecorder()
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {"smoothingMs": 120}}"#),
                                         environment: recorder.environment)
        defer { h.close() }
        try await h.session.apply()
        h.fake.emit(0x2130, params: [0x01])
        #expect(recorder.posts.isEmpty && recorder.frames.running)  // nothing yet; the glide has started
        let frames = recorder.frames.runToRest()
        #expect(recorder.dy == ScrollRecorder.upwardNotch && recorder.dx == 0)
        #expect(recorder.posts.count > 1)
        #expect(Double(frames) / 60 <= 0.12 * 2)  // spread over about the smoothing time, not longer
        #expect(Double(frames) / 60 >= 0.12 / 2)  // and not collapsed into the first frames
        #expect(!recorder.frames.running)  // idle again: the clock runs only while gliding
    }

    @Test func withoutSmoothingANotchPostsAtOnce() async throws {
        let recorder = ScrollRecorder()
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {"smoothingMs": 0}}"#),
                                         environment: recorder.environment)
        defer { h.close() }
        try await h.session.apply()
        h.fake.emit(0x2130, params: [0xFF])  // one notch down
        #expect(recorder.posts.count == 1 && recorder.dy == -ScrollRecorder.upwardNotch)
        #expect(!recorder.frames.running)
    }

    /// What one report of the notched wheel scrolls, in notches of `upwardNotch` (a negative count
    /// is down), with smoothing off so it posts at once.
    struct Notches: CustomTestStringConvertible, Sendable {
        var testDescription: String
        var config: String
        var report: UInt8
        var naturalScrolling = true
        var expected: Int
    }

    @Test(arguments: [
        // Synthetic events skip the system's flip, so the engine makes it itself.
        Notches(testDescription: "natural scrolling flips the direction",
                config: #"{"smoothScroll": {"smoothingMs": 0}}"#, report: 0x01, expected: 1),
        Notches(testDescription: "without natural scrolling it does not",
                config: #"{"smoothScroll": {"smoothingMs": 0}}"#, report: 0x01, naturalScrolling: false, expected: -1),
        Notches(testDescription: "several notches in one report scroll that many",
                config: #"{"smoothScroll": {"smoothingMs": 0, "acceleration": 0}}"#, report: 0x03, expected: 3),
        Notches(testDescription: "the configured wheel direction is applied in software",
                config: #"{"smoothScroll": {"smoothingMs": 0}, "scrollWheel": {"inverted": true}}"#, report: 0x01, expected: -1),
    ])
    func aReportScrollsTheNotchesItCarries(_ notches: Notches) async throws {
        let recorder = ScrollRecorder()
        recorder.naturalScrolling = notches.naturalScrolling
        let h = try await SessionHarness(.m750, config: SessionHarness.config(notches.config),
                                         environment: recorder.environment)
        defer { h.close() }
        try await h.session.apply()
        h.fake.emit(0x2130, params: [notches.report])
        #expect(recorder.dy == notches.expected * ScrollRecorder.upwardNotch)
        #expect(recorder.dx == 0)
    }

    @Test func quittingOrPausingHandsTheWheelBackEvenWhenAControlWillNotRelease() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {}, "buttons": {"back": "none"}}"#),
                                         instantTimeouts: true)
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.lowResWheelDiverted)
        #expect(Daemon.restoreSteps(quitting: [h.session.restoreSteps], pausing: []) == 1 + h.session.divertedControls.count)
        h.fake.failures[.init(0x1B04, 3)] = .timeout
        await h.session.restore()
        #expect(!h.fake.lowResWheelDiverted)
        #expect(wheelWrites(h.fake) == [[0x01], [0x00]])
    }

    @Test func aReloadThatTurnsSmoothScrollingOffHandsTheWheelBack() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(Self.smooth))
        defer { h.close() }
        try await h.session.apply()
        #expect(h.fake.lowResWheelDiverted)
        let inherited = h.session.inheritance
        h.session.close()
        let replacement = h.replacement(config: SessionHarness.nothing, inheriting: inherited)
        defer { replacement.close() }
        try await replacement.apply()
        #expect(!h.fake.lowResWheelDiverted)
    }

    @Test func aReplacementThatNeverAppliedStillHandsBackWhatItInherited() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(Self.smooth))
        defer { h.close() }
        try await h.session.apply()
        let inherited = h.session.inheritance
        h.session.close()
        let replacement = h.replacement(config: SessionHarness.nothing, inheriting: inherited)
        defer { replacement.close() }
        await replacement.restore()  // quitting between the reload and its first apply
        #expect(!h.fake.lowResWheelDiverted)
    }

    @Test func aMouseWithAHighResolutionWheelCountsNoNotchedStepToRestore() async throws {
        let h = try await SessionHarness(.mxMaster3S, config: SessionHarness.config(Self.smooth))
        defer { h.close() }
        try await h.session.apply()
        #expect(h.session.restoreSteps == 2 + h.session.divertedControls.count)  // main and thumb
    }

    @Test func pausingTheDaemonHandsTheWheelBack() async throws {
        let h = try DaemonHarness(Self.smooth)
        defer { h.close() }
        let m750 = FakeDevice.m750
        _ = try await h.adopt(m750)
        #expect(m750.lowResWheelDiverted)
        h.daemon.handle(Control(paused: true))
        try await eventually { !m750.lowResWheelDiverted }
    }

    @Test func aReloadThatTurnsItOffInTheDaemonHandsTheWheelBack() async throws {
        let h = try DaemonHarness(Self.smooth)
        defer { h.close() }
        let m750 = FakeDevice.m750
        _ = try await h.adopt(m750)
        #expect(m750.lowResWheelDiverted)
        try h.reload(SessionHarness.nothingJSON)
        _ = try await h.settled(m750)
        try await eventually { !m750.lowResWheelDiverted }
    }

    @Test func awayLeavesTheWheelNativeAndIgnoresLateNotches() async throws {
        let recorder = ScrollRecorder()
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {"smoothingMs": 0}}"#),
                                         environment: recorder.environment)
        defer { h.close() }
        try await h.session.apply()
        h.fake.emit(0x2130, params: [0x01])  // control: at home, a notch scrolls
        #expect(recorder.posts.count == 1)
        h.session.setAway(true)
        await h.session.diversion.drain()
        #expect(!h.fake.lowResWheelDiverted)
        h.fake.emit(0x2130, params: [0x01])
        #expect(recorder.posts.count == 1)  // the late notch posted nothing
        h.session.setAway(false)
        await h.session.diversion.drain()
        #expect(h.fake.lowResWheelDiverted)
        h.fake.emit(0x2130, params: [0x01])
        #expect(recorder.posts.count == 2)  // and back at home it scrolls again
    }

    @Test func withoutAccessibilityTheWheelStaysNative() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(Self.smooth),
                                         environment: .init(canPostEvents: false))
        defer { h.close() }
        try await h.session.apply()
        #expect(!h.fake.lowResWheelDiverted && wheelWrites(h.fake).isEmpty)
    }

    @Test func aWheelLeftDivertedByAPreviousProcessIsHandedBackOnce() async throws {
        let fake = FakeDevice.m750
        fake.responses[.init(0x2130, 0)] = [0x01]
        let h = try await SessionHarness(fake, config: SessionHarness.nothing)
        defer { h.close() }
        try await h.session.apply()
        #expect(!fake.lowResWheelDiverted && wheelWrites(fake) == [[0x00]])
        #expect(!h.session.wheelsMayBeDiverted)  // the clear took, so nothing is owed
        try await h.session.apply()
        #expect(wheelWrites(fake) == [[0x00]])  // already native: no second write
    }

    @Test func aMouseWithAHighResolutionWheelNeverTouchesTheNotchedOne() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.features[0x30] = 0x2130
        let h = try await SessionHarness(fake, config: SessionHarness.config(Self.smooth))
        defer { h.close() }
        try await h.session.apply()
        await h.session.restore()
        #expect(fake.mainWheelDiverted == false && fake.requests(feature: 0x2130, function: 0).isEmpty
                && fake.requests(feature: 0x2130, function: 1).isEmpty)
        #expect(fake.requests(feature: 0x2121, function: 2).count > 0)
    }

    // MARK: The wheel does not take the write

    private func refusingWheel() -> FakeDevice {
        let fake = FakeDevice.m750
        fake.ignoresLowResWheelWrites = true
        return fake
    }

    @Test func aWheelThatDoesNotReportDivertedAfterAskingIsLeftNativeAndNotOffered() async throws {
        let log = CapturedLog()
        let fake = refusingWheel()
        let h = try await SessionHarness(fake, config: SessionHarness.config(Self.smooth), identify: true)
        defer { h.close() }
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            try await h.session.apply()
            try await h.session.apply()  // asked once: a refusal is not retried by this session
        }
        #expect(!fake.lowResWheelDiverted)
        #expect(wheelWrites(fake) == [[0x01]])
        #expect(h.session.status.capabilities?.smoothScroll == false)
        #expect(log.lines.filter { $0.message.contains("does not report to PureMouse") }.count == 1)
        // The mouse does have 0x2130: the "lacks the feature" notice would say something false.
        #expect(log.lines.filter { $0.message.contains("smooth scrolling needs") }.isEmpty)
    }

    // MARK: A wheel left diverted

    private func startingDiverted(_ fake: FakeDevice = .m750) -> FakeDevice {
        fake.responses[.init(0x2130, 0)] = [0x01]
        return fake
    }

    @Test func aWheelLeftDivertedWhoseFirstClearFailsStaysOwedUntilConfirmedNative() async throws {
        let fake = startingDiverted()
        fake.failures[.init(0x2130, 1)] = .timeout
        let h = try await SessionHarness(fake, config: SessionHarness.nothing, instantTimeouts: true)
        defer { h.close() }
        let controls = h.session.divertedControls.count
        #expect(!h.session.wheelsMayBeDiverted && h.session.restoreSteps == controls)  // control: nothing owed yet
        await #expect(throws: (any Error).self) { try await h.session.apply() }
        #expect(fake.lowResWheelDiverted && h.session.wheelsMayBeDiverted)
        #expect(h.session.restoreSteps > h.session.divertedControls.count)  // quitting waits for it
        fake.failures[.init(0x2130, 1)] = nil
        try await h.session.apply()  // the next apply clears it and, confirmed, stops owing it
        #expect(!fake.lowResWheelDiverted && !h.session.wheelsMayBeDiverted)
    }

    @Test func aWheelLeftDivertedWhoseFirstClearFailsIsHandedBackOnQuit() async throws {
        let fake = startingDiverted()
        fake.failures[.init(0x2130, 1)] = .timeout
        let h = try await SessionHarness(fake, config: SessionHarness.nothing, instantTimeouts: true)
        defer { h.close() }
        await #expect(throws: (any Error).self) { try await h.session.apply() }
        fake.failures[.init(0x2130, 1)] = nil
        await h.session.restore()
        #expect(!fake.lowResWheelDiverted)
    }

    @Test func aClearTheMouseAcknowledgesButDoesNotTakeIsNotConfirmedNative() async throws {
        let fake = startingDiverted()
        fake.ignoresLowResWheelWrites = true
        let h = try await SessionHarness(fake, config: SessionHarness.nothing)
        defer { h.close() }
        await #expect(throws: (any Error).self) { try await h.session.apply() }
        #expect(fake.lowResWheelDiverted && h.session.wheelsMayBeDiverted)
    }
}
