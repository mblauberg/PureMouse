import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// A mouse whose 0x0003 read failed in transit is keyed by nothing yet, and reads it again until
/// it has an answer: a device's own `devices` entry then applies, as after a slot announcement.
@Suite(.quietLog) @MainActor
struct IdentityRetryTests {
    static let key = SessionDeviceConfigTests.m1  // the MX Master 3S fixture
    static let config = #"{"dpi": 1600, "devices": {"\#(key)": {"dpi": 1200}}}"#

    private func identityReads(_ fake: FakeDevice) -> Int {
        fake.requests(feature: 0x0003, function: 0).count
    }

    /// The session on `fake` once it has the key and has finished configuring.
    private func keyed(_ h: DaemonHarness, _ fake: FakeDevice) async throws -> Session {
        var session: Session?
        try await eventually {
            session = h.daemon.sessions.values.first { $0.device.interface === fake.transport }
            return session.map { $0.deviceKey == Self.key && !$0.isConfiguring } ?? false
        }
        return try #require(session)
    }

    @Test func aDroppedIdentityReplyIsReadAgainAfterTheFirstConfigure() async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        mx.dropFirstLookup(of: 0x0003)
        #expect(await h.tryAdopting(mx) == .adopted)
        #expect(mx.droppedLookups == [0x0003])
        _ = try await keyed(h, mx)
        #expect(mx.dpi == 1200)
        #expect(h.daemon.status(running: true).devices.map(\.model) == [Self.key])
    }

    @Test func anIdentityThatKeepsTimingOutIsReadOncePerConfigureAndThenAppliesOnReload() async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        mx.failures[.init(0x0003, 0)] = .timeout
        let first = try await h.adopt(mx)
        #expect(first.deviceKey == nil && mx.dpi == 1600)
        // One read at adoption and one after its configure; no loop behind them.
        #expect(identityReads(mx) == 2)
        mx.failures.removeAll()
        try h.reload()
        _ = try await keyed(h, mx)
        #expect(mx.dpi == 1200)
        #expect(identityReads(mx) == 3)
    }

    @Test func aReconnectReadsAnUnresolvedIdentityAgain() async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        mx.failures[.init(0x0003, 0)] = .timeout
        let session = try await h.adopt(mx)
        mx.failures.removeAll()
        session.configure()
        _ = try await keyed(h, mx)
        #expect(mx.dpi == 1200)
    }

    @Test func aDeviceErrorIsAnAnswerAndIsNeverReadAgain() async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        mx.failures[.init(0x0003, 0)] = .error(2)
        let session = try await h.adopt(mx)
        #expect(session.deviceKey == "p\(String(mx.transport.productID, radix: 16))")
        try h.reload()
        let reloaded = try await h.settled(mx)
        reloaded.configure()
        _ = try await h.settled(mx)
        #expect(identityReads(mx) == 1)
    }

    @Test func aKnownIdentityIsNeverReadAgain() async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        let session = try await h.adopt(mx)
        #expect(session.deviceKey == Self.key)
        try h.reload()
        let reloaded = try await h.settled(mx)
        reloaded.configure()
        _ = try await h.settled(mx)
        #expect(identityReads(mx) == 1)
    }

    /// The retry's device-error answer lands just before the slot's first announcement names the
    /// product: the answer was read with no product to key by, so the announcement must still
    /// complete the key, not be lost between the two.
    @Test func anAnswerBeforeTheFirstSlotAnnouncementStillGetsTheProductKey() async throws {
        let h = try DaemonHarness(#"{"dpi": 1600, "devices": {"pb02c": {"dpi": 800}}}"#)
        defer { h.close() }
        let m750 = FakeDevice.m750
        m750.onReceiver(slot: 2)
        m750.failures[.init(0x0003, 0)] = .timeout
        let session = try await h.adopt(m750)
        #expect(session.deviceKey == nil && m750.dpi == 1600)
        session.device.timeout = .seconds(30)
        let reads = identityReads(m750)
        session.configure()
        try await eventually { identityReads(m750) > reads }
        // Within one turn, so the retry's continuation runs after the announcement.
        let request = try #require(m750.requests(feature: 0x0003, function: 0).last)
        m750.failures.removeAll()
        m750.transport.deliver(FakeTransport.error(to: request, code: 2))
        m750.announce(product: 0xB02C)
        try? await eventually {
            h.daemon.sessions.values.first { $0.device.interface === m750.transport }
                .map { $0.deviceKey == "pb02c" && !$0.isConfiguring } ?? false
        }
        #expect(h.daemon.sessions.values.map(\.deviceKey) == ["pb02c"])
        #expect(m750.dpi == 800)
        try h.reload()
        _ = try await h.settled(m750)
        #expect(m750.dpi == 800)
    }
}
