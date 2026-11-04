import HIDPP
import HIDPPTesting
import Testing
@testable import puremouse

@Suite(.quietLog) @MainActor
struct SessionOfflineTests {
    /// `onReceiver`: the mouse is in a receiver slot, the only place a short 0x41 connection
    /// notification comes from.
    private func offline(onReceiver: Bool = false) async throws -> (SessionHarness, HandClock) {
        let clock = HandClock()
        let fake = FakeDevice.mxMaster3S
        if onReceiver { fake.onReceiver(slot: 1) }
        let h = try await SessionHarness(fake, config: SessionHarness.config(#"{"buttons":{"back":"none"}}"#),
            environment: .init(canPostEvents: true, configureRetryDelay: .milliseconds(1), now: { clock.now }))
        h.fake.failures[.init(0x1B04, 3)] = .error(2)
        h.session.configure()
        try await eventually { !h.session.status.online && !h.session.isConfiguring }
        return (h, clock)
    }

    @Test func batteryEventReconfiguresAfterThreeFailedAttempts() async throws {
        let (h, clock) = try await offline()
        defer { h.close() }
        h.fake.failures.removeAll()
        clock.now += Session.offlineReconfigureGap
        h.fake.emit(0x1004, params: [75, 4, 0, 0])
        try await eventually { h.session.status.online && !h.session.isConfiguring }
        #expect(h.fake.control(0x53)?.diverted == true)
    }

    /// The mouse returns (0x41 link up) while the last configure attempt sleeps before giving up.
    @Test func linkUpDuringFinalRetryIsNotLost() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.onReceiver(slot: 1)
        let h = try await SessionHarness(fake, config: SessionHarness.config(#"{"buttons":{"back":"none"}}"#),
            environment: .init(canPostEvents: true, configureRetryDelay: .milliseconds(100)))
        defer { h.close() }
        h.fake.failures[.init(0x1B04, 3)] = .error(2)
        h.session.configure()
        try await eventually { h.fake.controlWrites(cid: 0x53).count >= 3 }
        h.fake.failures.removeAll()
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index, featureIndex: 0x41,
                                function: 0, softwareID: 0, params: [0x00]))
        try await eventually { h.session.status.online && !h.session.isConfiguring }
        // Outlast the superseded task's sleep: its end must not undo or clear the new configure.
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.session.status.online && !h.session.isConfiguring)
        #expect(h.fake.control(0x53)?.diverted == true)
    }

    /// The mouse reconnects (0x1D4B) after apply diverted its buttons but before apply ends: the
    /// mouse has forgotten them, so the configure under way must give way to a new one.
    @Test func reconnectMidApplyReappliesAndDropsHeldButtons() async throws {
        let h = try await SessionHarness(config: SessionHarness.config(#"{"buttons":{"back":"none"}}"#))
        defer { h.close() }
        h.device.timeout = .seconds(5)
        // Hold back the reply to the first DPI read, which comes after the diversion step.
        let answer = h.fake.transport.answer
        var stalled: Report?
        h.fake.transport.answer = { [fake = h.fake] request in
            if stalled == nil, fake.feature(of: request) == 0x2201, request.function == 2 {
                stalled = request
                return nil
            }
            return try answer?(request)
        }
        h.session.configure()
        try await eventually { stalled != nil }
        #expect(h.fake.control(0x53)?.diverted == true)
        h.fake.emit(0x1B04, params: [0, 0x53])
        #expect(h.session.held.pressed == [0x53])
        h.fake.setReporting(0x53)
        h.fake.emit(0x1D4B, params: [1, 0, 0])
        #expect(h.session.held.pressed.isEmpty)
        // The superseded configure ends now; the new one (waiting out its 100 ms) keeps its handle.
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.session.isConfiguring)
        // The stalled read now completes; it must not end configuration with the button native.
        if let stalled { h.fake.transport.deliver(FakeTransport.reply(to: stalled, params: [0, 3, 232])) }
        try await eventually { h.fake.control(0x53)?.diverted == true && !h.session.isConfiguring }
        #expect(h.session.status.online)
    }

    @Test func eventStormStartsOneConfigureAndWaitsThirtySecondsAfterItEnds() async throws {
        let (h, clock) = try await offline()
        defer { h.close() }
        h.fake.transport.sent.removeAll()
        // No retry immediately after a failed configure.
        for _ in 0..<20 { h.fake.emit(0x1004, params: [75, 4, 0, 0]) }
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
        clock.now += Session.offlineReconfigureGap
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            for _ in 0..<20 { h.fake.emit(0x1004, params: [75, 4, 0, 0]) }
            try await eventually { !h.session.isConfiguring }
        }
        #expect(log.lines.filter { $0.message.contains("configure attempt") }.count == 3)
        let sent = h.fake.transport.sent.count
        clock.now += .seconds(29)
        for _ in 0..<20 { h.fake.emit(0x1004, params: [75, 4, 0, 0]) }
        #expect(!h.session.isConfiguring && h.fake.transport.sent.count == sent)
    }

    @Test func linkDownNeverStartsAConfigure() async throws {
        let (h, clock) = try await offline(onReceiver: true)
        defer { h.close() }
        clock.now += Session.offlineReconfigureGap
        h.fake.transport.sent.removeAll()
        h.session.handle(Report(reportID: .short, deviceIndex: h.device.index,
            featureIndex: 0x41, function: 0, softwareID: 0, params: [0x40]))
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }

    @Test func finishedSessionIgnoresEvents() async throws {
        let (h, clock) = try await offline()
        defer { h.close() }
        h.session.close()
        clock.now += Session.offlineReconfigureGap
        h.fake.transport.sent.removeAll()
        h.session.handle(Report(deviceIndex: directDeviceIndex, featureIndex: 9,
                                function: 0, softwareID: 0, params: [75, 4, 0, 0]))
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }
}
