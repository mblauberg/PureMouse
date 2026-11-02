import HIDPP
import HIDPPTesting
import Testing
@testable import puremouse

@MainActor
struct SessionDiversionTests {
    @Test func freshAdoptionReleasesStaleTemporaryDiversion() async throws {
        let fake = FakeDevice.mxMaster3S
        let index = try #require(fake.controls.firstIndex { $0.cid == 0x56 })
        fake.controls[index].reporting[2] = 0x11
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        #expect(!fake.controls[index].diverted && !fake.controls[index].rawXY)
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
        let index = try #require(fake.controls.firstIndex { $0.cid == 0x56 })
        fake.controls[index].reporting[2] = 5
        let log = CapturedLog()
        try await Log.$capture.withValue({ log.append($0) }) {
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
        #expect(fake.controls[index].persistent && fake.controls[index].diverted)
        #expect(!fake.transport.sent.contains { isWrite($0, to: 0x56, on: fake) })
        #expect(log.lines.filter { $0.level == "info" && $0.message.contains("0x0056") && $0.message.contains("Logi Options+") }.count == 1)
    }

    @Test func timeoutLeavesScanPendingForTheNextApply() async throws {
        let fake = FakeDevice.mxMaster3S
        let index = try #require(fake.controls.firstIndex { $0.cid == 0x56 })
        fake.controls[index].reporting[2] = 1
        let h = try await SessionHarness(fake, inheriting: .init(fresh: true))
        defer { h.close() }
        fake.failures[.init(0x1B04, 2)] = .timeout
        await #expect(throws: HIDPPError.timeout) { try await h.session.apply() }
        #expect(fake.controls[index].diverted)
        #expect(reportingReads(fake).count == 1)
        fake.failures.removeAll()
        try await h.session.apply()
        #expect(!fake.controls[index].diverted)
        #expect(reportingReads(fake).count == 7)
    }

    @Test func configureRetriesAFailedFreshScan() async throws {
        let h = try await SessionHarness(inheriting: .init(fresh: true))
        defer { h.close() }
        h.fake.failures[.init(0x1B04, 2)] = .timeout
        h.session.configure()
        try await SessionHarness.eventually { !h.session.status.online && !h.session.isConfiguring }
        #expect(reportingReads(h.fake).count == 3)
        h.fake.failures.removeAll()
        h.session.configure()
        try await SessionHarness.eventually { h.session.status.online && !h.session.isConfiguring }
        #expect(reportingReads(h.fake).count == 9)
    }

    private func reportingReads(_ fake: FakeDevice) -> [Report] {
        fake.transport.sent.filter { fake.feature(of: $0) == 0x1B04 && $0.function == 2 }
    }

    private func isWrite(_ report: Report, to cid: UInt16, on fake: FakeDevice) -> Bool {
        fake.feature(of: report) == 0x1B04 && report.function == 3 && report.params.count >= 2
            && UInt16(report.params[0]) << 8 | UInt16(report.params[1]) == cid
    }
}
