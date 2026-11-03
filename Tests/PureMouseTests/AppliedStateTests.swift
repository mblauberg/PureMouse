import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// Whether a mouse's settings are on it (`Status.Device.applied`), how fast they come back after a
/// wake, a reconnect or a host switch-back, and what the daemon reads for About This Mouse.
@Suite(.quietLog) @MainActor
struct AppliedStateTests {
    private static let config = #"{"buttons":{"back":"none"}}"#
    typealias State = Status.Device.Applied.State

    /// The live schedule (`SessionEnvironment.live`'s timeout and delay), with the permission
    /// checks off and a fixed wall clock.
    private static func live(date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SessionEnvironment {
        SessionEnvironment(canPostEvents: true, configureRetryDelay: SessionEnvironment.reapplyRetryDelay,
                           attemptTimeout: SessionEnvironment.reapplyAttemptTimeout, date: { date })
    }

    private func harness(_ fake: FakeDevice = .mxMaster3S, environment: SessionEnvironment) async throws -> SessionHarness {
        try await SessionHarness(fake, config: SessionHarness.config(Self.config), environment: environment)
    }

    /// A time a test moves by hand.
    private final class Hand: @unchecked Sendable {
        var now = ContinuousClock.now
    }

    /// The applied states a session publishes, consecutive repeats dropped.
    @MainActor private final class Transitions {
        private(set) var states: [State] = []
        private(set) var changes = 0
        init(_ session: Session) {
            session.onChange = { [unowned self, unowned session] in
                changes += 1
                guard let state = session.status.applied?.state, states.last != state else { return }
                states.append(state)
            }
        }
    }

    // MARK: Transitions

    @Test func aConfigureMovesApplyingThenAppliedWithTheTime() async throws {
        let at = Date(timeIntervalSince1970: 1_700_000_123)
        let h = try await harness(environment: Self.live(date: at))
        defer { h.close() }
        let seen = Transitions(h.session)
        #expect(h.session.status.applied == nil)
        h.session.configure()
        #expect(h.session.status.applied == nil)  // nothing has answered yet
        try await eventually { h.session.status.applied?.state == .applied }
        #expect(h.session.status.applied == .init(state: .applied, at: at))
        #expect(seen.states == [.applying, .applied])
    }

    @Test func aReloadAppliesAgainThroughApplying() async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied }
        let next = h.replacement(config: try SessionHarness.config(Self.config), environment: Self.live())
        defer { next.close() }
        #expect(next.status.applied?.state == .applied)  // inherited until the new session starts
        let seen = Transitions(next)
        next.configure()
        try await eventually { next.status.applied?.state == .applied && !next.isConfiguring }
        #expect(seen.states == [.applying, .applied])
    }

    @Test func anIdleSessionPublishesNothingAfterItIsApplied() async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        let seen = Transitions(h.session)
        let before = h.session.status
        try await Task.sleep(for: .milliseconds(400))
        #expect(seen.changes == 0)
        #expect(h.session.status == before)
    }

    @Test func theDaemonWritesOnlyWhenTheStatusChanges() async throws {
        let h = try DaemonHarness(#"{"buttons":{"back":"none"}}"#)
        defer { h.close() }
        let session = try await h.adopt(FakeDevice.mxMaster3S)
        #expect(session.status.applied?.state == .applied)
        let first = h.daemon.status(running: true)
        try await Task.sleep(for: .milliseconds(300))
        // Nothing but the start time and process are in it, and neither moves.
        #expect(h.daemon.status(running: true) == first)
    }

    // MARK: Retries and Apply Settings Again

    @Test func exhaustedRetriesAreNotAppliedAndApplyAgainClearsIt() async throws {
        let h = try await SessionHarness(.mxMaster3S, config: SessionHarness.config(Self.config))
        defer { h.close() }
        h.fake.failures[.init(0x1B04, 3)] = .error(2)
        let seen = Transitions(h.session)
        h.session.configure()
        try await eventually { !h.session.isConfiguring }
        #expect(h.session.status.applied == .init(state: .notApplied))
        #expect(!h.session.status.online)
        #expect(seen.states == [.applying, .notApplied])
        h.fake.failures.removeAll()
        // At once, not behind the 30 s offline guard.
        h.session.reapply()
        #expect(h.session.status.applied == .init(state: .notApplied))  // kept until the mouse answers
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        #expect(h.session.status.online && h.fake.control(0x53)?.diverted == true)
        #expect(seen.states == [.applying, .notApplied, .applying, .applied])
    }

    @Test func applyAgainDoesNothingForAMouseThatIsApplied() async throws {
        let h = try await SessionHarness(.mxMaster3S, config: SessionHarness.config(Self.config))
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        h.fake.transport.sent.removeAll()
        h.session.reapply()
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }

    @Test func theMenusRequestStartsAnotherApplyOnEachNewTokenOnly() async throws {
        let h = try DaemonHarness(#"{"buttons":{"back":"none"}}"#)
        defer { h.close() }
        let fake = FakeDevice.mxMaster3S
        fake.failures[.init(0x1B04, 3)] = .error(2)
        #expect(await h.tryAdopting(fake) == .adopted)
        let session = try await h.settled(fake)
        #expect(session.status.applied?.state == .notApplied)
        fake.failures.removeAll()
        h.daemon.handle(Control(reapply: 7))
        try await eventually { session.status.applied?.state == .applied && !session.isConfiguring }
        // The same token again is the same request: it does not start another apply.
        fake.failures[.init(0x1B04, 3)] = .error(2)
        h.daemon.handle(Control(reapply: 7))
        #expect(!session.isConfiguring && session.status.applied?.state == .applied)
    }

    // MARK: Asleep is not failed

    private static func linkReport(_ h: SessionHarness, up: Bool) -> Report {
        Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41, function: 0, softwareID: 0,
               params: [up ? 0x00 : 0x40])
    }

    /// A short schedule: three attempts, nothing slow, whatever the live one is.
    private static let quick = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1),
                                                  attemptTimeout: .milliseconds(30))

    @Test func aMouseThatAnswersNothingIsAsleepNotNotApplied() async throws {
        let h = try await harness(environment: Self.quick)
        defer { h.close() }
        h.fake.transport.timing = .never  // every request, not one write
        let seen = Transitions(h.session)
        h.session.configure()
        try await eventually(within: .seconds(5)) { !h.session.isConfiguring }
        #expect(h.session.attemptsMade == 3)  // all three were made
        #expect(h.session.status.applied == nil && !h.session.status.online)
        #expect(!seen.states.contains(.notApplied))
    }

    @Test func aMouseThatAnsweredAndStillFailedIsNotApplied() async throws {
        let h = try await harness(environment: Self.quick)
        defer { h.close() }
        h.fake.failures[.init(0x1B04, 3)] = .timeout  // everything else answers
        h.session.configure()
        try await eventually(within: .seconds(5)) { !h.session.isConfiguring }
        #expect(h.session.status.applied == .init(state: .notApplied))
    }

    @Test func anAsleepMouseThatAnswersAgainIsConfiguredByItsNextEvent() async throws {
        let hand = Hand()
        var environment = Self.quick
        environment.now = { hand.now }
        let h = try await harness(environment: environment)
        defer { h.close() }
        h.fake.transport.timing = .never
        h.session.configure()
        try await eventually(within: .seconds(5)) { !h.session.isConfiguring }
        #expect(h.session.status.applied == nil)
        h.fake.transport.timing = .nextTurn
        hand.now += Session.offlineReconfigureGap  // events drive the retry, at most once a gap
        h.fake.emit(0x1D4B, params: [1, 0, 0])
        try await eventually(within: .seconds(5)) { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        #expect(h.session.status.online)
    }

    @Test func aLinkGoingDownEndsTheConfigureAndSaysNothingOfTheSettings() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await harness(fake, environment: Self.quick)
        defer { h.close() }
        fake.transport.timing = .never
        h.session.configure()
        try await eventually { h.session.attemptsMade == 1 }
        h.session.handle(Self.linkReport(h, up: false))
        #expect(!h.session.isConfiguring)
        #expect(h.session.status.applied == nil && !h.session.status.online)
        try await Task.sleep(for: .milliseconds(200))  // longer than the attempts would have taken
        #expect(h.session.attemptsMade == 1 && h.session.status.applied == nil)
        fake.transport.timing = .nextTurn
        h.session.handle(Self.linkReport(h, up: true))
        try await eventually(within: .seconds(5)) { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
    }

    // MARK: Timeout ownership

    @Test func aRetiredConfigureLeavesItsReplacementsTimeoutAlone() async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        h.fake.transport.timing = .never
        h.session.configure()
        try await eventually { h.session.attemptsMade == 1 }
        let next = h.replacement(config: try SessionHarness.config(Self.config), environment: Self.live())
        defer { next.close() }
        next.configure()
        try await eventually { next.attemptsMade == 1 }
        h.session.close()  // the retired session's configure ends now
        try await eventually { !h.session.isConfiguring }
        for _ in 0..<5 { await Task.yield() }
        #expect(h.device.effectiveTimeout == SessionEnvironment.reapplyAttemptTimeout)
    }

    @Test func aCancelledConfigureLeavesRestoresTimeoutAlone() async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        h.fake.transport.timing = .never
        h.session.configure()
        try await eventually { h.session.attemptsMade > 1 }
        // The mouse answers nothing, so restore holds its timeout for as long as its writes wait.
        let restoring = Task { await h.session.restore() }
        try await eventually { h.device.effectiveTimeout == Session.restoreTimeout }
        try await eventually { !h.session.isConfiguring }  // the cancelled configure has ended
        for _ in 0..<5 { await Task.yield() }
        #expect(h.device.effectiveTimeout == Session.restoreTimeout)
        await restoring.value
        #expect(h.device.effectiveTimeout == h.device.timeout)
    }

    @Test func aReapplyAlongsideADPIRequestForAnotherMouseStillReachesThisOne() async throws {
        let h = try DaemonHarness(#"{"buttons":{"back":"none"}}"#)
        defer { h.close() }
        let fake = FakeDevice.mxMaster3S
        fake.failures[.init(0x1B04, 3)] = .error(2)
        #expect(await h.tryAdopting(fake) == .adopted)
        let session = try await h.settled(fake)
        #expect(session.status.applied?.state == .notApplied)
        fake.failures.removeAll()
        h.daemon.handle(Control(useConfiguredDPI: 5, device: "some-other-mouse", reapply: 9))
        try await eventually { session.status.applied?.state == .applied && !session.isConfiguring }
    }

    // MARK: The 2 s bound

    /// The live schedule's shape, shortened (60 ms a request, 10 ms between
    /// attempts), so a silent mouse costs a fraction of a second. The tests count attempts
    /// instead of timing them: a mouse that starts answering as attempt `k` begins is applied by
    /// attempt `k + 1` (so `k` is 1 or 2: a third silent attempt leaves nothing to apply by, and the
    /// request in flight when the mouse starts answering may be one whose timeout fails it), whatever else is running on the machine. The live durations, and
    /// wall-clock figures, are the constants' test below and the rig's
    /// (`scripts/measure-reconnect.sh`).
    private static let scaled = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(10),
                                                   attemptTimeout: .milliseconds(60))

    private func attemptsUntilApplied(_ h: SessionHarness, silentAttempts k: Int,
                                      start: () -> Void) async throws -> Int {
        h.fake.transport.timing = .never  // every request unanswered, not one write
        let first = h.session.attemptsMade
        start()
        try await eventually(within: .seconds(5)) { h.session.attemptsMade - first == k }  // attempt k has begun
        h.fake.transport.timing = .nextTurn  // the mouse answers from here on
        try await eventually(within: .seconds(5)) { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        return h.session.attemptsMade - first
    }

    @Test(arguments: [1, 2]) func aWakeIsAppliedByTheAttemptAfterTheMouseAnswers(silentAttempts: Int) async throws {
        let h = try await harness(environment: Self.scaled)
        defer { h.close() }
        let attempts = try await attemptsUntilApplied(h, silentAttempts: silentAttempts) { h.session.configureAfterWake() }
        #expect(attempts <= silentAttempts + 1)
        #expect(h.fake.control(0x53)?.diverted == true)
    }

    @Test(arguments: [1, 2]) func aReconnectIsAppliedByTheAttemptAfterTheMouseAnswers(silentAttempts: Int) async throws {
        let h = try await harness(environment: Self.scaled)
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        // The mouse announces itself (0x1D4B) while it still answers nothing, then answers.
        let attempts = try await attemptsUntilApplied(h, silentAttempts: silentAttempts) {
            h.fake.emit(0x1D4B, params: [1, 0, 0])
        }
        #expect(attempts <= silentAttempts + 1)
    }

    @Test(arguments: [1, 2]) func aHostSwitchBackIsAppliedByTheAttemptAfterTheLinkComesUp(silentAttempts: Int) async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await harness(fake, environment: Self.scaled)
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        // The mouse goes to another computer, forgetting what was set, and returns.
        h.session.handle(Self.linkReport(h, up: false))
        h.fake.resetReporting()
        #expect(!h.session.status.online)
        let attempts = try await attemptsUntilApplied(h, silentAttempts: silentAttempts) {
            h.session.handle(Self.linkReport(h, up: true))
        }
        #expect(attempts <= silentAttempts + 1)
        #expect(h.fake.control(0x53)?.diverted == true && h.session.status.online)
    }

    @Test func aMouseSilentThroughTheWindowNeverShowsApplying() async throws {
        let h = try await harness(environment: Self.scaled)
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        // Asleep after a wake: every request goes unanswered, through all three attempts.
        h.fake.transport.timing = .never
        let seen = Transitions(h.session)
        let first = h.session.attemptsMade
        h.session.configureAfterWake()
        #expect(h.session.status.applied?.state == .applied)  // what it showed, until it answers or gives up
        try await eventually(within: .seconds(5)) { !h.session.isConfiguring }
        #expect(h.session.attemptsMade - first == 3)
        #expect(h.session.status.applied == nil && !h.session.status.online)
        #expect(seen.states.isEmpty)  // no applying, no notApplied
    }

    @Test func aFreshSessionSilentThroughTheWindowPublishesNoAppliedState() async throws {
        let h = try await harness(environment: Self.scaled)
        defer { h.close() }
        h.fake.transport.timing = .never
        let seen = Transitions(h.session)
        h.session.configure()
        try await eventually(within: .seconds(5)) { !h.session.isConfiguring && h.session.attemptsMade >= 3 }
        #expect(h.session.status.applied == nil)
        #expect(seen.states.isEmpty)
    }

    @Test func aMouseAnsweringOnTheSecondAttemptShowsApplyingThenApplied() async throws {
        let h = try await harness(environment: Self.scaled)
        defer { h.close() }
        let seen = Transitions(h.session)
        _ = try await attemptsUntilApplied(h, silentAttempts: 1) { h.session.configure() }
        #expect(seen.states == [.applying, .applied])
    }

    @Test func theLiveScheduleKeepsEachRetryWithinAboutASecond() {
        // What follows the mouse answering: the request in flight (at most one timeout), the
        // retry delay and one apply (about a second on a real mouse): the figures behind
        // "within two seconds" in docs/how-it-works.md.
        let wait = SessionEnvironment.reapplyAttemptTimeout + SessionEnvironment.reapplyRetryDelay
        #expect(wait <= .milliseconds(800))
        #expect(SessionEnvironment.live.attemptTimeout == SessionEnvironment.reapplyAttemptTimeout)
        #expect(SessionEnvironment.live.configureRetryDelay == SessionEnvironment.reapplyRetryDelay)
    }

    @Test func aWakeLeavesAMouseTheReceiverSaidIsAwayAlone() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await harness(fake, environment: Self.live())
        defer { h.close() }
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                function: 0, softwareID: 0, params: [0x40]))
        h.fake.transport.sent.removeAll()
        h.session.configureAfterWake()
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }

    // MARK: Reads for About This Mouse

    private static func withHosts(_ fake: FakeDevice) -> FakeDevice {
        fake.hosts = ["Studio", "MacBook Air", nil]
        fake.currentHost = 0
        fake.firmware = [[0, 0x52, 0x42, 0x4D, 0x22, 0x01, 0x00, 0x15, 1, 0, 0, 0, 0, 0, 0, 0]]
        return fake
    }

    @Test func aConfigureReadsFirmwareAndHostsAndWritesNothingToThem() async throws {
        let h = try await harness(Self.withHosts(.mxMaster3S), environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.hosts != nil && !h.session.isConfiguring }
        let status = h.session.status
        #expect(status.firmware == "RBM 22.01 B0015")
        #expect(status.hosts == .init(current: 0, slots: [.init(name: "Studio", paired: true),
                                                          .init(name: "MacBook Air", paired: true),
                                                          .init(name: nil, paired: false)]))
        // Reads only: no change-host command (0x1814 function 1), no setter, nothing else beyond
        // the reads wrapped in HIDPP.
        #expect(h.fake.hostWrites.isEmpty)
        #expect(h.fake.requests(feature: 0x1814, function: 1).isEmpty)
        #expect(h.fake.requests(feature: 0x1815, function: 2).isEmpty && h.fake.requests(feature: 0x1815, function: 4).isEmpty)
    }

    @Test func theHostIsReadAgainAfterTheMouseSwitchesAway() async throws {
        let h = try await harness(Self.withHosts(.mxMaster3S), environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.hosts?.current == 0 && !h.session.isConfiguring }
        h.fake.currentHost = 1
        h.fake.emit(0x1D4B, params: [1, 0, 0])
        try await eventually { h.session.status.hosts?.current == 1 }
        #expect(h.fake.hostWrites.isEmpty)
    }

    @Test func aMouseWithoutHostDataLeavesThemOut() async throws {
        // The M750 lists neither feature's data: both answer with an error.
        let h = try await harness(.m750, environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        #expect(h.session.status.hosts == nil)
        #expect(h.session.status.firmware == nil)
        #expect(h.session.status.online)  // a read that fails does not fail the apply
    }

    @Test func aMouseWithOnlyChangeHostGivesTheCountAndTheCurrentHost() async throws {
        let fake = FakeDevice(features: [1: 0x0001, 2: 0x1814, 3: 0x1B04])
        fake.controls = [FakeDevice.Control(cid: 0x53)]
        fake.hosts = ["A", "B", "C"]
        fake.currentHost = 2
        let h = try await SessionHarness(fake, config: SessionHarness.config(Self.config), environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.hosts != nil && !h.session.isConfiguring }
        #expect(h.session.status.hosts == .init(current: 2, slots: [.init(), .init(), .init()]))
        #expect(fake.hostWrites.isEmpty)
    }
}
