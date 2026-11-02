import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@MainActor
struct SessionApplyTests {
    @Test func exampleAppliesAndRestoresWheelsBeforeControls() async throws {
        let config = try SessionHarness.example()
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        #expect(Set(h.fake.controls.filter(\.diverted).map(\.cid)) == config.boundControls)
        #expect(h.fake.controls.first { $0.cid == 0xC3 }?.rawXY == true)
        #expect(h.fake.mainWheelDiverted && h.fake.mainWheelHighResolution)
        #expect(h.fake.thumbWheelDiverted)
        let resolutions = try await AdjustableDPI.resolutions(h.device)
        #expect(h.fake.dpi == resolutions.nearest(to: config.dpi!))
        h.fake.transport.sent.removeAll()
        await h.session.restore()
        #expect(h.fake.controls.allSatisfy { !$0.diverted && !$0.rawXY })
        #expect(!h.fake.mainWheelDiverted && !h.fake.mainWheelHighResolution)
        #expect(!h.fake.thumbWheelDiverted)
        let writes = h.fake.transport.sent.filter {
            (h.fake.feature(of: $0) == 0x2121 && $0.function == 2)
                || (h.fake.feature(of: $0) == 0x2150 && $0.function == 2)
                || (h.fake.feature(of: $0) == 0x1B04 && $0.function == 3)
        }
        #expect(writes.prefix(2).compactMap { h.fake.feature(of: $0) } == [0x2121, 0x2150])
        #expect(writes.dropFirst(2).allSatisfy { h.fake.feature(of: $0) == 0x1B04 })
    }

    @Test func permissionDenialLeavesWheelsNativeAndLogsReason() async throws {
        let log = CapturedLog()
        try await Log.$capture.withValue({ log.append($0) }) {
            let h = try await SessionHarness(config: SessionHarness.example(),
                                             environment: .init(canPostEvents: false))
            defer { h.close() }
            try await h.session.apply()
            #expect(!h.fake.mainWheelDiverted && !h.fake.thumbWheelDiverted)
        }
        #expect(log.lines.contains { $0.message.contains("no Accessibility permission; leaving the wheels native") })
    }

    @Test func probeDumpRoundTripsFixtureState() async {
        let fake = FakeDevice.mxMaster3S
        let device = fake.endpoint(softwareIDs: 0x2...0x7)
        defer { device.close() }
        var lines: [String] = []
        await Probe.dump(device) { lines.append($0) }
        let parsed = FakeDevice.probe(lines.joined(separator: "\n"))
        #expect(parsed.name == fake.name)
        #expect(parsed.features == fake.features)
        #expect(parsed.controls == fake.controls)
        #expect(parsed.responses == fake.responses)
        #expect(fake.transport.sent.allSatisfy { (0x2...0x7).contains($0.softwareID) })
    }
}
