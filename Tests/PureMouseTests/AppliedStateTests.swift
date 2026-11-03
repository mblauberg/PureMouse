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
        #expect(h.session.status.applied == .init(state: .applying))
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
        #expect(h.session.status.applied == .init(state: .applying))
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

    // MARK: The 2 s bound

    /// How long after the mouse starts answering its settings are applied, whatever ends the wait.
    private func timeToApplied(_ h: SessionHarness, answeringAfter wait: Duration,
                               start: () -> Void) async throws -> Duration {
        h.fake.failures[.init(0x1B04, 3)] = .timeout
        start()
        try await Task.sleep(for: wait)
        h.fake.failures.removeAll()
        let answered = ContinuousClock.now
        try await eventually(within: .seconds(4)) { h.session.status.applied?.state == .applied }
        return ContinuousClock.now - answered
    }

    @Test(arguments: [100, 650, 1300]) func aWakeIsAppliedWithinTwoSecondsOfTheMouseAnswering(answeringAfterMs: Int) async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        let took = try await timeToApplied(h, answeringAfter: .milliseconds(answeringAfterMs)) { h.session.configureAfterWake() }
        #expect(took < .seconds(2), "took \(took)")
        #expect(h.fake.control(0x53)?.diverted == true)
    }

    @Test func aReconnectIsAppliedWithinTwoSecondsOfTheMouseAnswering() async throws {
        let h = try await harness(environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        // The mouse announces itself (0x1D4B) while it still answers nothing, then answers.
        let took = try await timeToApplied(h, answeringAfter: .milliseconds(300)) {
            h.fake.emit(0x1D4B, params: [1, 0, 0])
        }
        #expect(took < .seconds(2), "took \(took)")
    }

    @Test func aHostSwitchBackIsAppliedWithinTwoSecondsOfTheLinkComingUp() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await harness(fake, environment: Self.live())
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        // The mouse goes to another computer, forgetting what was set, and returns.
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                function: 0, softwareID: 0, params: [0x40]))
        h.fake.resetReporting()
        #expect(!h.session.status.online)
        let answered = ContinuousClock.now
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                function: 0, softwareID: 0, params: [0x00]))
        try await eventually(within: .seconds(4)) { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        #expect(ContinuousClock.now - answered < .seconds(2))
        #expect(h.fake.control(0x53)?.diverted == true && h.session.status.online)
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
