import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// Deadlines a test arms and fires by hand: the fake clock for a press's hold and double-click wait.
@MainActor
final class ManualDeadlines {
    final class Entry {
        let delay: Duration
        let fire: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(delay: Duration, fire: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.fire = fire
        }
    }

    private(set) var armed: [Entry] = []
    /// Deadlines neither fired nor cancelled.
    var pending: [Entry] { armed.filter { !$0.cancelled && !$0.fired } }

    func arm(_ delay: Duration, _ fire: @escaping @MainActor () -> Void) -> Deadline {
        let entry = Entry(delay: delay, fire: fire)
        armed.append(entry)
        return Deadline { entry.cancelled = true }
    }

    /// Fires the first pending deadline, as its time coming would.
    func fire() {
        guard let entry = pending.first else {
            Issue.record("no deadline is armed")
            return
        }
        entry.fired = true
        entry.fire()
    }
}

/// A mouse button posted for a control.
struct NativePost: Equatable {
    let cid: UInt16
    let down: Bool
}

/// What a session performs and posts, in place of the system.
@MainActor
final class TriggerRecorder {
    let deadlines = ManualDeadlines()
    var performed: [Action] = []
    /// What was performed, less the `none` of a click that does nothing.
    var acted: [Action] { performed.filter { $0 != .none } }
    var left: [Bool] = []
    var middle: [Bool] = []
    /// The ordinary mouse buttons posted for a control: its ID and whether it went down.
    var native: [NativePost] = []
    var doubleClickSeconds: Double? = 0.4

    var environment: SessionEnvironment {
        var environment = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        environment.deadline = { [unowned self] in deadlines.arm($0, $1) }
        environment.performSystem = { [unowned self] in performed.append($0) }
        environment.heldButtons = { [unowned self] in
            HeldButtons(post: { self.native.append(NativePost(cid: $0, down: $1)); return true },
                        postMiddle: { self.middle.append($0); return true },
                        postLeft: { self.left.append($0); return true })
        }
        environment.doubleClickSeconds = { [unowned self] in doubleClickSeconds }
        return environment
    }
}

@Suite(.quietLog) @MainActor
struct TriggerSessionTests {
    static let forward: UInt16 = 0x56
    static let back: UInt16 = 0x53

    private func session(_ json: String, _ fake: FakeDevice = .mxMaster3S) async throws -> (SessionHarness, TriggerRecorder) {
        let recorder = TriggerRecorder()
        let h = try await SessionHarness(fake, config: SessionHarness.config(json), environment: recorder.environment)
        try await h.session.apply()
        return (h, recorder)
    }

    private func press(_ h: SessionHarness, _ cids: UInt16...) async {
        var params: [UInt8] = []
        for cid in cids { params += [UInt8(cid >> 8), UInt8(cid & 0xFF)] }
        h.fake.emit(0x1B04, params: params.isEmpty ? [0, 0] : params)
        await h.session.diversion.drain()
        await h.session.deviceActions.drain()
    }

    private func release(_ h: SessionHarness) async { await press(h) }

    private func settle(_ h: SessionHarness) async {
        await h.session.diversion.drain()
        await h.session.deviceActions.drain()
    }

    // MARK: Click, hold, double-click

    @Test func aClickAloneFiresOnPressAndArmsNothing() async throws {
        let (h, r) = try await session(#"{"buttons": {"back": "navigateBack", "forward": {"click": "navigateForward"}}}"#)
        defer { h.close() }
        await press(h, Self.back)
        #expect(r.performed == [.navigateBack] && r.deadlines.armed.isEmpty)
        await release(h)
        await press(h, Self.forward)
        #expect(r.performed == [.navigateBack, .navigateForward] && r.deadlines.armed.isEmpty)
        await release(h)
        #expect(r.performed.count == 2 && h.session.presses.isEmpty)
    }

    @Test func withAHoldTheClickFiresOnReleaseAndTheHoldOnceAfterwhichNoClick() async throws {
        let (h, r) = try await session(#"{"holdMs": 500, "buttons": {"forward": {"click": "navigateForward", "hold": "missionControl"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(r.performed.isEmpty)
        #expect(r.deadlines.pending.map(\.delay) == [.milliseconds(500)])
        await release(h)
        #expect(r.performed == [.navigateForward])
        #expect(r.deadlines.pending.isEmpty && h.session.presses.isEmpty)

        await press(h, Self.forward)
        r.deadlines.fire()
        #expect(r.performed == [.navigateForward, .missionControl])
        await release(h)
        #expect(r.performed == [.navigateForward, .missionControl])
        #expect(r.deadlines.pending.isEmpty && h.session.presses.isEmpty)
    }

    @Test func withADoubleClickALoneClickFiresAfterTheInterval() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"click": "navigateForward", "doubleClick": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(r.deadlines.armed.isEmpty)
        await release(h)
        #expect(r.performed.isEmpty)
        // The system's interval, read as the click starts waiting.
        #expect(r.deadlines.pending.map(\.delay) == [.milliseconds(400)])
        r.deadlines.fire()
        #expect(r.performed == [.navigateForward])
        #expect(r.deadlines.pending.isEmpty && h.session.presses.isEmpty)
    }

    @Test func aSecondPressInTimeIsTheDoubleClick() async throws {
        let (h, r) = try await session(#"{"doubleClickMs": 250, "buttons": {"forward": {"click": "navigateForward", "doubleClick": "appExpose", "hold": "launchpad"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        #expect(r.deadlines.pending.map(\.delay) == [.milliseconds(250)])
        await press(h, Self.forward)
        #expect(r.performed == [.appExpose] && r.deadlines.pending.isEmpty)
        await release(h)
        #expect(r.performed == [.appExpose])
        #expect(r.deadlines.pending.isEmpty && h.session.presses.isEmpty)
    }

    @Test func anotherButtonDoesNotWaitBehindALoneClick() async throws {
        let (h, r) = try await session(#"{"buttons": {"back": "navigateBack", "forward": {"click": "navigateForward", "doubleClick": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        await press(h, Self.back)
        #expect(r.performed == [.navigateForward, .navigateBack] && r.deadlines.pending.isEmpty)
    }

    // MARK: A table with no click is the mouse's own click

    @Test func aHoldOnlyTableOnANativeButtonClicksNativelyOnAQuickRelease() async throws {
        for cid: UInt16 in [Self.forward, Self.back, 0x52] {
            let key = cid == Self.forward ? "forward" : cid == Self.back ? "back" : "middle"
            let (h, r) = try await session(#"{"holdMs": 500, "buttons": {"\#(key)": {"hold": "missionControl"}}}"#)
            defer { h.close() }
            await press(h, cid)
            #expect(r.native.isEmpty, "the click waits to see whether the hold comes")
            await release(h)
            #expect(r.native == [NativePost(cid: cid, down: true), NativePost(cid: cid, down: false)])
            #expect(r.acted.isEmpty && h.session.presses.isEmpty && h.session.held.native.isEmpty)
        }
    }

    @Test func aHoldOnlyTableStillFiresTheHoldWithoutAClick() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"hold": "missionControl"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        r.deadlines.fire()
        await release(h)
        #expect(r.performed == [.missionControl] && r.native.isEmpty)
    }

    @Test func aDoubleClickOnlyTableOnANativeButtonClicksNativelyAfterTheInterval() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"doubleClick": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        #expect(r.native.isEmpty && r.acted.isEmpty)
        r.deadlines.fire()
        #expect(r.native == [NativePost(cid: Self.forward, down: true), NativePost(cid: Self.forward, down: false)])
        #expect(r.acted.isEmpty && h.session.presses.isEmpty && h.session.held.native.isEmpty)
    }

    @Test func aDoubleClickOnlyTableStillFiresTheDoubleClickWithoutAClick() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"doubleClick": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        await press(h, Self.forward)
        await release(h)
        #expect(r.performed == [.appExpose] && r.native.isEmpty && r.deadlines.pending.isEmpty)
    }

    @Test func aLoneNativeClickDoesNotWaitBehindAnotherButtonsPress() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"doubleClick": "appExpose"}, "back": "navigateBack"}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        await press(h, Self.back)
        #expect(r.native == [NativePost(cid: Self.forward, down: true), NativePost(cid: Self.forward, down: false)])
        #expect(r.performed == [.navigateBack])
    }

    @Test func aTableWithNoClickOnAButtonWithNoNativeBehaviourDoesNothingOnAQuickPress() async throws {
        // The gesture button has no behaviour of its own. A top-level table is laid over the default
        // set, so its click is named "none" here, which a table with other triggers reads as unset.
        let gesture: UInt16 = 0x00C3
        for json in [#"{"buttons": {"gesture": {"click": "none", "hold": "missionControl"}}}"#,
                     #"{"buttons": {"gesture": {"click": "none", "hold": "none", "doubleClick": "appExpose"}}}"#] {
            let (h, r) = try await session(json)
            defer { h.close() }
            await press(h, gesture)
            await release(h)
            if !r.deadlines.pending.isEmpty { r.deadlines.fire() }
            #expect(r.native.isEmpty && r.acted.isEmpty && h.session.presses.isEmpty, "\(r.native) \(r.performed) \(json)")
        }
    }

    @Test func aTableWithNoClickOnTheDPIButtonCyclesTheSpeedOnAQuickPress() async throws {
        let (h, r) = try await session(#"{"dpi": 800, "dpiPresets": [800, 1600], "buttons": {"0x00fd": {"hold": "missionControl"}}}"#, .m750)
        defer { h.close() }
        await press(h, 0xFD)
        #expect(h.fake.dpi == 800)
        await release(h)
        #expect(h.fake.dpi == 1600 && r.native.isEmpty && r.acted.isEmpty)
    }

    @Test func holdAndMoveWithNoClickLeavesAQuickReleaseToTheMouse() async throws {
        let (h, r) = try await session(#"{"buttons": {"back": {"up": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, Self.back)
        await release(h)
        #expect(r.native == [NativePost(cid: Self.back, down: true), NativePost(cid: Self.back, down: false)])
        #expect(r.acted.isEmpty && h.session.presses.isEmpty)
    }

    @Test func aTableOfOnlyANoneClickStillDoesNothing() async throws {
        let (h, r) = try await session(#"{"buttons": {"back": {"click": "none"}}}"#)
        defer { h.close() }
        await press(h, Self.back)
        await release(h)
        #expect(r.native.isEmpty && r.acted.isEmpty)
    }

    @Test func aTriggerSetToNoneIsNotWatchedForSoTheClickIsImmediate() throws {
        let config = try SessionHarness.config("""
            {"buttons": {"forward": {"click": "navigateForward", "doubleClick": "appExpose"}},
             "apps": {"com.example.x": {"buttons": {"forward": {"doubleClick": "none"}}}}}
            """)
        #expect(!PressPlan(config.bindings[Self.forward]).immediate)
        let app = PressPlan(config.settings(forApp: "com.example.x")?.bindings[Self.forward])
        #expect(app.immediate && app.click == .navigateForward)
    }

    @Test func droppingThePressesCancelsTheirDeadlines() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"click": "navigateForward", "doubleClick": "appExpose"}, "back": {"click": "navigateBack", "hold": "launchpad"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        await press(h, Self.back)
        #expect(r.deadlines.pending.count == 1)  // forward's wait gave way to back's press
        h.session.dropHeld()
        #expect(r.deadlines.pending.isEmpty && h.session.presses.isEmpty)
        #expect(r.performed == [.navigateForward])
    }

    @Test func holdAndMoveKeepsItsClickWhenNothingMoves() async throws {
        let (h, r) = try await session(#"{"buttons": {"gesture": {"click": "missionControl", "up": "appExpose"}}}"#)
        defer { h.close() }
        await press(h, 0xC3)
        #expect(r.performed.isEmpty && r.deadlines.armed.isEmpty)
        await release(h)
        #expect(r.performed == [.missionControl] && h.session.presses.isEmpty)
    }

    // MARK: Precise Pointer

    @Test func precisePointerOnAClickSlowsUntilRelease() async throws {
        let (h, r) = try await session(#"{"dpi": 1600, "buttons": {"forward": "precisePointer"}}"#)
        defer { h.close() }
        #expect(h.fake.dpi == 1600)
        await press(h, Self.forward)
        #expect(h.fake.dpi == 800 && h.session.state.dpi == 1600)
        #expect(r.deadlines.armed.isEmpty)
        await release(h)
        #expect(h.fake.dpi == 1600 && h.session.state.preciseFrom == nil)
    }

    @Test func precisePointerOnAClickOwnsTheButton() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"click": {"precisePointer": 400}, "doubleClick": "appExpose", "hold": "launchpad"}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400 && r.deadlines.armed.isEmpty)
        await release(h)
        #expect(h.fake.dpi == 1000 && r.performed.isEmpty && r.deadlines.armed.isEmpty)
    }

    @Test func precisePointerOnAHoldStartsAfterTheDelayAndAQuickClickStillClicks() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"click": "navigateForward", "hold": {"precisePointer": 400}}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        await release(h)
        #expect(r.performed == [.navigateForward] && h.fake.dpi == 1000)
        await press(h, Self.forward)
        r.deadlines.fire()
        await settle(h)
        #expect(h.fake.dpi == 400)
        await release(h)
        #expect(h.fake.dpi == 1000 && r.performed == [.navigateForward])
    }

    @Test func aCycleDPIWhileHeldIsNotUndone() async throws {
        let (h, _) = try await session(#"{"dpi": 800, "dpiPresets": [800, 1600], "buttons": {"forward": {"precisePointer": 400}, "back": "cycleDPI"}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400)
        await press(h, Self.forward, Self.back)
        #expect(h.fake.dpi == 1600)
        await press(h, Self.back)
        #expect(h.fake.dpi == 1600)
        await release(h)
        #expect(h.fake.dpi == 1600 && h.session.state.liveDPI == 1600)
    }

    @Test func precisePointerEndsOnAHandOff() async throws {
        let (h, _) = try await session(#"{"buttons": {"forward": {"precisePointer": 400}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400)
        h.session.setAway(true)
        await settle(h)
        #expect(h.fake.dpi == 1000 && h.session.precise == nil)
    }

    @Test func precisePointerEndsOnPauseAndQuit() async throws {
        let (h, _) = try await session(#"{"buttons": {"forward": {"precisePointer": 400}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400 && h.session.restoreSteps > 0)
        await h.session.restore()
        #expect(h.fake.dpi == 1000 && h.session.state.preciseFrom == nil)
    }

    @Test func precisePointerLostToALinkDownIsUndoneByTheNextApply() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let (h, _) = try await session(#"{"buttons": {"forward": {"precisePointer": 400}}}"#, fake)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400)
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index,
            featureIndex: 0x41, function: 0, softwareID: 0, params: [0x40]))
        await settle(h)
        #expect(h.session.precise == nil && h.session.state.preciseFrom == 1000)
        try await h.session.apply()
        #expect(h.fake.dpi == 1000 && h.session.state.preciseFrom == nil)
    }

    @Test func precisePointerHeldThroughAReloadIsUndoneByTheReplacement() async throws {
        let (h, r) = try await session(#"{"buttons": {"forward": {"precisePointer": 400}}}"#)
        defer { h.close() }
        await press(h, Self.forward)
        #expect(h.fake.dpi == 400)
        h.session.close()
        let replacement = h.replacement(config: try SessionHarness.config(#"{"buttons": {"forward": "navigateForward"}}"#),
                                        environment: r.environment)
        #expect(replacement.state.preciseFrom == 1000)
        try await replacement.apply()
        #expect(h.fake.dpi == 1000 && replacement.state.preciseFrom == nil)
        replacement.close()
    }

    // MARK: Drag Lock

    @Test func dragLockClicksToStartAndAgainToLetGo() async throws {
        let (h, r) = try await session(#"{"buttons": {"top": "dragLock"}}"#)
        defer { h.close() }
        await press(h, 0xC4)
        await release(h)
        #expect(r.left == [true] && h.session.held.dragging)
        await press(h, 0xC4)
        await release(h)
        #expect(r.left == [true, false] && !h.session.held.dragging)
    }

    @Test func dragLockIsLetGoWhenThePressesAreDropped() async throws {
        let (h, r) = try await session(#"{"buttons": {"top": {"click": "navigateForward", "hold": "dragLock"}}}"#)
        defer { h.close() }
        await press(h, 0xC4)
        r.deadlines.fire()
        await release(h)
        #expect(r.left == [true] && r.performed.isEmpty)
        h.session.setAway(true)
        #expect(r.left == [true, false] && !h.session.held.dragging)
    }

    @Test func dragLockIsLetGoOnPauseAndQuit() async throws {
        let (h, r) = try await session(#"{"buttons": {"top": "dragLock"}}"#)
        defer { h.close() }
        await press(h, 0xC4)
        await release(h)
        await h.session.restore()
        #expect(r.left == [true, false])
    }
}
