import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// The fake-device leg of the reconnect rig (`scripts/measure-reconnect.sh`, docs/development.md):
/// N cycles each of a wake, a reconnect and a host switch-back, on the live retry schedule, timing
/// the apply from the moment the fake starts answering. It prints one `rig <kind> <cycle> <ms>` line
/// per cycle and fails above two seconds. Off unless `PUREMOUSE_RIG_CYCLES` is set, so the ordinary
/// run does not repeat what `AppliedStateTests` checks, which counts attempts rather than timing them:
/// wall-clock figures are this suite's and need a machine doing nothing else.
@Suite(.serialized, .quietLog, .enabled(if: ReconnectRig.cycles > 0)) @MainActor
struct ReconnectRigTests {
    private static let config = #"{"buttons":{"back":"none"}}"#
    private static let limit: Duration = .seconds(2)

    private func harness(_ fake: FakeDevice = .mxMaster3S) async throws -> SessionHarness {
        let environment = SessionEnvironment(canPostEvents: true, configureRetryDelay: SessionEnvironment.reapplyRetryDelay,
                                             attemptTimeout: SessionEnvironment.reapplyAttemptTimeout)
        return try await SessionHarness(fake, config: SessionHarness.config(Self.config), environment: environment)
    }

    /// The fake answers no request at all for `silence`, then answers; the clock starts at the first answer.
    private func cycle(_ kind: String, _ index: Int, silence: Duration, h: SessionHarness,
                       trigger: () -> Void) async throws {
        h.fake.transport.timing = .never  // every request unanswered, as a sleeping mouse leaves them
        trigger()
        try await Task.sleep(for: silence)
        h.fake.transport.timing = .nextTurn
        let answered = ContinuousClock.now
        try await eventually(within: .seconds(5)) { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        let took = ContinuousClock.now - answered
        let ms = took.components.seconds * 1000 + took.components.attoseconds / 1_000_000_000_000_000
        print("rig \(kind) \(index) \(ms)")
        #expect(took < Self.limit, "\(kind) \(index) took \(took)")
    }

    @Test func wakeCycles() async throws {
        let h = try await harness()
        defer { h.close() }
        for index in 1...ReconnectRig.cycles {
            try await cycle("wake", index, silence: ReconnectRig.silence(index), h: h) { h.session.configureAfterWake() }
        }
    }

    @Test func reconnectCycles() async throws {
        let h = try await harness()
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        for index in 1...ReconnectRig.cycles {
            // The mouse announces itself (0x1D4B) while it still answers nothing.
            try await cycle("reconnect", index, silence: ReconnectRig.silence(index), h: h) {
                h.fake.emit(0x1D4B, params: [1, 0, 0])
            }
        }
    }

    @Test func hostSwitchBackCycles() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await harness(fake)
        defer { h.close() }
        h.session.configure()
        try await eventually { h.session.status.applied?.state == .applied && !h.session.isConfiguring }
        for index in 1...ReconnectRig.cycles {
            // Away to another computer (link down), then back (link up) with the mouse still waking.
            h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                    function: 0, softwareID: 0, params: [0x40]))
            h.fake.resetReporting()
            try await cycle("switch-back", index, silence: ReconnectRig.silence(index), h: h) {
                h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                        function: 0, softwareID: 0, params: [0x00]))
            }
        }
    }
}

enum ReconnectRig {
    /// `PUREMOUSE_RIG_CYCLES`: how many of each kind to run; 0 or unset leaves the suite off.
    static let cycles = Int(ProcessInfo.processInfo.environment["PUREMOUSE_RIG_CYCLES"] ?? "") ?? 0

    /// How long the mouse stays silent after the trigger: 0 to 1.3 s in steps, so the cycles cover
    /// the first, second and third attempts of a configure.
    static func silence(_ index: Int) -> Duration { .milliseconds((index * 130) % 1400) }
}
