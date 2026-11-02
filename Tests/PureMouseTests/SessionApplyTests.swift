import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@Suite(.quietLog) @MainActor
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
        // The notched wheel is diverted, so quitting hands it back.
        #expect(h.fake.lowResWheelDiverted)
        #expect(h.session.restoreSteps == 1 + h.session.divertedControls.count)
    }

    @Test func restoreStepsCountWheelsOfUnknownPresence() async throws {
        let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll":{}}"#))
        defer { h.close() }
        // Nothing looked up yet: `restore` may resolve and write any of the three wheels.
        #expect([0x2121, 0x2130, 0x2150].allSatisfy { h.device.knownPresence(of: $0) == nil })
        #expect(h.session.restoreSteps == 3 + h.session.divertedControls.count)
        try await h.session.apply()
        // Only the notched wheel is there, and diverted.
        #expect(h.session.restoreSteps == 1 + h.session.divertedControls.count)
    }

    @Test func enhancedTimeoutReachesConfigureRetry() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.features[0x0E] = 0x2111
        fake.failures[.init(0x2111, 1)] = .timeout
        let h = try await SessionHarness(fake)
        defer { h.close() }
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            h.session.configure()
            try await eventually { !h.session.status.online }
        }
        #expect(log.lines.filter { $0.message.contains("configure attempt") }.count == 3)
        #expect(fake.requests(feature: 0x2111, function: 1).count == 3)
    }

    @Test func exampleAppliesAndRestoresWheelsBeforeControls() async throws {
        var config = try SessionHarness.example()
        // Off the fixture's 200-8000 step 50 grid, so the write proves the snap.
        config.dpi = 1630
        let h = try await SessionHarness(config: config)
        defer { h.close() }
        try await h.session.apply()
        #expect(Set(h.fake.controls.filter(\.diverted).map(\.cid)) == config.boundControls)
        #expect(h.fake.control(0xC3)?.rawXY == true)
        #expect(h.fake.mainWheelDiverted && h.fake.mainWheelHighResolution)
        #expect(h.fake.thumbWheelDiverted)
        #expect(h.fake.dpi == 1650)
        h.fake.transport.sent.removeAll()
        await h.session.restore()
        #expect(h.fake.controls.allSatisfy { !$0.diverted && !$0.rawXY })
        #expect(!h.fake.mainWheelDiverted && !h.fake.mainWheelHighResolution)
        #expect(!h.fake.thumbWheelDiverted)
        let restoring: Set<FakeDevice.Call> = [.init(0x2121, 2), .init(0x2150, 2), .init(0x1B04, 3)]
        let writes = h.fake.transport.sent.filter { restoring.contains(.init(h.fake.feature(of: $0) ?? 0xFFFF, $0.function)) }
        #expect(writes.prefix(2).compactMap { h.fake.feature(of: $0) } == [0x2121, 0x2150])
        #expect(writes.dropFirst(2).allSatisfy { h.fake.feature(of: $0) == 0x1B04 })
    }

    @Test func permissionDenialLeavesWheelsNativeAndLogsReason() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try await SessionHarness(config: SessionHarness.example(),
                                             environment: .init(canPostEvents: false))
            defer { h.close() }
            try await h.session.apply()
            #expect(!h.fake.mainWheelDiverted && !h.fake.thumbWheelDiverted)
        }
        #expect(log.lines.contains { $0.message.contains("no Accessibility permission; leaving the wheels native") })
    }

    /// `puremouse probe` output read back by `FakeDevice.probe` rebuilds every fixture, which is
    /// the contract the fixtures rely on.
    @Test(arguments: ["3S", "Master 4", "Ergo", "G305", "Superstrike", "M750"])
    func probeDumpRoundTripsFixtureState(_ name: String) async {
        let fake: FakeDevice = switch name {
        case "3S": .mxMaster3S
        case "Master 4": .mxMaster4
        case "Ergo": .mxErgo
        case "G305": .g305
        case "Superstrike": .superstrike
        default: .m750
        }
        let device = fake.endpoint(softwareIDs: 0x2...0x7)
        defer { device.close() }
        var lines: [String] = []
        await Probe.dump(device) { lines.append($0) }
        let parsed = FakeDevice.probe(lines.joined(separator: "\n"))
        #expect(parsed.name == fake.name)
        #expect(parsed.kind == fake.kind)
        #expect(parsed.features == fake.features)
        #expect(parsed.controls == fake.controls)
        #expect(parsed.responses == fake.responses)
        if name == "3S" {
            #expect((try? await DeviceIdentity.transportIDs(device)) == [.bluetoothLE: 0xB034])
        }
        #expect(fake.transport.sent.allSatisfy { (0x2...0x7).contains($0.softwareID) })
    }
}
