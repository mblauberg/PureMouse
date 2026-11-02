import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@MainActor
struct SessionApplyTests {
    @Test func m750DoesNotRepeatMissingWheelAndClutchLookups() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll":{},"buttons":{"middle":"toggleScrollMode"}}"#))
        defer { h.close() }
        try await h.session.apply()
        for id: UInt16 in [0x2121, 0x2150, 0x2110, 0x2111] {
            #expect(h.device.knownPresence(of: id) == false)
        }
        h.fake.transport.sent.removeAll()
        try await h.session.apply()
        #expect(h.fake.transport.sent.allSatisfy { $0.featureIndex != 0 })
        h.fake.transport.sent.removeAll()
        h.fake.emit(0x1B04, params: [0, 0x52])
        await h.session.deviceActions.drain()
        #expect(h.fake.transport.sent.isEmpty)
        #expect(h.session.restoreSteps == h.session.divertedControls.count)
    }

    @Test func enhancedTimeoutReachesConfigureRetry() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.features[5] = 0x2111
        fake.failures[.init(0x2111, 1)] = .timeout
        let h = try await SessionHarness(fake)
        defer { h.close() }
        let log = CapturedLog()
        try await Log.$capture.withValue({ log.append($0) }) {
            h.session.configure()
            try await SessionHarness.eventually { !h.session.status.online }
        }
        #expect(log.lines.filter { $0.message.contains("configure attempt") }.count == 3)
        #expect(fake.transport.sent.filter { fake.feature(of: $0) == 0x2111 && $0.function == 1 }.count == 3)
    }

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
        #expect((try? await DeviceIdentity.transportIDs(device)) == [.bluetoothLE: 0xB034, .wireless: 0x4091])
        #expect(fake.transport.sent.allSatisfy { (0x2...0x7).contains($0.softwareID) })
    }
}
