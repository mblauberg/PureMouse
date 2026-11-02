import HIDPP
import HIDPPTesting
import Testing
@testable import puremouse

@MainActor
struct SessionOfflineTests {
    private func offline() async throws -> (SessionHarness, TestTime) {
        let clock = TestTime()
        let h = try await SessionHarness(config: SessionHarness.config(#"{"buttons":{"back":"none"}}"#),
            environment: .init(canPostEvents: true, configureRetryDelay: .milliseconds(1), now: { clock.now }))
        h.fake.failures[.init(0x1B04, 3)] = .error(2)
        h.session.configure()
        try await SessionHarness.eventually { !h.session.status.online && !h.session.isConfiguring }
        return (h, clock)
    }

    @Test func batteryEventReconfiguresAfterThreeFailedAttempts() async throws {
        let (h, clock) = try await offline()
        defer { h.close() }
        h.fake.failures.removeAll()
        clock.now += Session.offlineReconfigureGap
        h.fake.emit(0x1004, params: [75, 4, 0, 0])
        try await SessionHarness.eventually { h.session.status.online && !h.session.isConfiguring }
        #expect(h.fake.controls.first { $0.cid == 0x53 }?.diverted == true)
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
        try await Log.$capture.withValue({ log.append($0) }) {
            for _ in 0..<20 { h.fake.emit(0x1004, params: [75, 4, 0, 0]) }
            try await SessionHarness.eventually { !h.session.isConfiguring }
        }
        #expect(log.lines.filter { $0.message.contains("configure attempt") }.count == 3)
        let sent = h.fake.transport.sent.count
        clock.now += .seconds(29)
        for _ in 0..<20 { h.fake.emit(0x1004, params: [75, 4, 0, 0]) }
        #expect(!h.session.isConfiguring && h.fake.transport.sent.count == sent)
    }

    @Test func linkDownNeverStartsAConfigure() async throws {
        let (h, clock) = try await offline()
        defer { h.close() }
        clock.now += Session.offlineReconfigureGap
        h.fake.transport.sent.removeAll()
        h.session.handle(Report(reportID: .short, deviceIndex: directDeviceIndex,
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

@MainActor
private final class TestTime {
    var now = ContinuousClock.now
}
