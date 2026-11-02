import HIDPP
import HIDPPTesting
import Testing
@testable import puremouse

@Suite(.quietLog) @MainActor
struct SessionDiversionTests {
    @Test func exampleScansOnlyTheUnboundVirtualControl() async throws {
        let h = try await SessionHarness(config: SessionHarness.example(), inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        #expect(reportingReads(h.fake).count == 1)
    }

    @Test func captureBeforeApplyAlsoPreservesPersistentDiversion() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true, persistent: true)
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        h.session.beginCapture()
        await h.session.diversion.drain()
        await h.session.restore()
        #expect(fake.controlWrites(cid: 0x56).isEmpty)
    }

    @Test func freshAdoptionReleasesStaleTemporaryDiversion() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true, rawXY: true)
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        #expect(fake.control(0x56)?.diverted == false && fake.control(0x56)?.rawXY == false)
        // Six divertable, unbound controls in this illustrative 3S fixture (including virtual).
        #expect(reportingReads(fake).count == 6)
        fake.transport.sent.removeAll()
        try await h.session.apply()
        #expect(reportingReads(fake).isEmpty)
    }

    @Test func reloadDoesNotReadReportingAgain() async throws {
        let h = try await SessionHarness(inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        let inherited = h.session.inheritance
        h.session.close()
        let controls = try await ReprogControls.controls(h.device)
        h.fake.transport.sent.removeAll()
        let replacement = Session(device: h.device, name: h.fake.name, id: "replacement",
            controls: controls, config: .empty, inheriting: inherited,
            environment: .init(canPostEvents: true))
        defer { replacement.close() }
        try await replacement.apply()
        #expect(reportingReads(h.fake).isEmpty)
    }

    @Test func persistentDiversionIsLoggedOnceAndNeverWritten() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true, persistent: true)
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
            defer { h.close() }
            try await h.session.apply()
            try await h.session.apply()
            h.session.beginCapture()
            await h.session.diversion.drain()
            h.session.endCapture()
            await h.session.diversion.drain()
            await h.session.restore()
        }
        #expect(fake.control(0x56)?.persistent == true && fake.control(0x56)?.diverted == true)
        #expect(fake.controlWrites(cid: 0x56).isEmpty)
        #expect(log.lines.filter { $0.level == "info" && $0.message.contains("0x0056") && $0.message.contains("Logi Options+") }.count == 1)
    }

    @Test func timeoutLeavesScanPendingForTheNextApply() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true)
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        fake.failures[.init(0x1B04, 2)] = .timeout
        await #expect(throws: HIDPPError.timeout) { try await h.session.apply() }
        #expect(fake.control(0x56)?.diverted == true)
        #expect(reportingReads(fake).count == 1)
        fake.failures.removeAll()
        try await h.session.apply()
        #expect(fake.control(0x56)?.diverted == false)
        #expect(reportingReads(fake).count == 7)
    }

    @Test func configureRetriesAFailedFreshScan() async throws {
        let h = try await SessionHarness(inheriting: .init(fresh: true))
        defer { h.close() }
        h.fake.failures[.init(0x1B04, 2)] = .timeout
        h.session.configure()
        try await eventually { !h.session.status.online && !h.session.isConfiguring }
        #expect(reportingReads(h.fake).count == 3)
        h.fake.failures.removeAll()
        h.session.configure()
        try await eventually { h.session.status.online && !h.session.isConfiguring }
        #expect(reportingReads(h.fake).count == 9)
    }

    @Test func reloadBeforeAFreshScanSucceedsStillReleasesStaleDiversion() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true)
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        fake.failures[.init(0x1B04, 2)] = .timeout
        await #expect(throws: HIDPPError.timeout) { try await h.session.apply() }
        let inherited = h.session.inheritance
        #expect(inherited.fresh)
        h.session.close()
        fake.failures.removeAll()
        let controls = try await ReprogControls.controls(h.device)
        let replacement = Session(device: h.device, name: fake.name, id: "replacement", controls: controls,
                                  config: .empty, inheriting: inherited, environment: .init(canPostEvents: true))
        defer { replacement.close(); h.device.close() }
        try await replacement.apply()
        #expect(fake.control(0x56)?.diverted == false)
        #expect(!replacement.inheritance.fresh)
    }

    @Test func deviceErrorOnOneControlSkipsItWithoutBlockingApply() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.setReporting(0x56, diverted: true)
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        fake.failures[.init(0x1B04, 2)] = .error(2)
        try await h.session.apply()
        #expect(h.session.status.online)
        // Every control answered (with an error), so the scan is done and not repeated.
        let reads = reportingReads(fake).count
        #expect(reads == 6)
        try await h.session.apply()
        #expect(reportingReads(fake).count == reads)
        #expect(fake.control(0x56)?.diverted == true)
    }

    private func reportingReads(_ fake: FakeDevice) -> [Report] {
        fake.requests(feature: 0x1B04, function: 2)
    }
}
