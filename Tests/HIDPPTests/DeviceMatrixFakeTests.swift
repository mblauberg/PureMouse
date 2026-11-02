@testable import HIDPP
import HIDPPTesting
import Testing

/// The wrappers for 0x2130 and 0x2202 against the fakes that carry them, and what each matrix
/// fixture reports. The wheel and DPI bytes of the hand-built fixtures are Solaar's layouts.
@MainActor struct LowResWheelFakeTests {
    @Test func theErgoWheelStartsNativeAndIsDivertedAndHandedBackTemporarily() async throws {
        let fake = FakeDevice.mxErgo
        let device = fake.endpoint()
        defer { device.close() }
        #expect(!fake.lowResWheelDiverted)
        #expect(try await LowResWheel.diverted(device) == false)
        try await LowResWheel.setDiverted(device, true)
        #expect(fake.lowResWheelDiverted)
        #expect(try await LowResWheel.diverted(device))
        try await LowResWheel.setDiverted(device, false)
        #expect(!fake.lowResWheelDiverted)
        // Only the bit-0 byte is ever written: no persistent form exists for this feature.
        #expect(fake.requests(feature: 0x2130, function: 1).map(\.params.first) == [0x01, 0x00])
    }

    @Test func aNotchEventReachesTheHandlerParsed() async throws {
        let fake = FakeDevice.m750
        let device = fake.endpoint()
        defer { device.close() }
        let index = try #require(fake.features.first { $0.value == 0x2130 }?.key)
        _ = try await device.featureIndex(of: LowResWheel.id)
        var seen: [LowResWheel.Event] = []
        device.onEvent = { report in
            if report.featureIndex == index, let event = LowResWheel.parse(function: report.function, params: report.params) {
                seen.append(event)
            }
        }
        fake.emit(0x2130, params: [0xFF])
        try await eventually { !seen.isEmpty }
        #expect(seen == [.scroll(notches: -1)])
    }
}

@MainActor struct ExtendedDPIFakeTests {
    @Test func theSuperstrikeReportsItsCapabilitiesListAndReading() async throws {
        let fake = FakeDevice.superstrike
        let device = fake.endpoint()
        defer { device.close() }
        let caps = try await ExtendedDPI.capabilities(device)
        #expect(caps == .init(separateY: true, liftOffDistance: true))
        let list = try await ExtendedDPI.resolutions(device, capabilities: caps)
        #expect(list.values.first == 100 && list.values.last == 25600 && list.values.count == 511)
        #expect(try await ExtendedDPI.get(device) == .init(x: 800, liftOffDistance: 2))
        // Both axes' lists were read, since Y is separate.
        #expect(fake.requests(feature: 0x2202, function: 2).map(\.params) == [[0, 0, 0], [0, 1, 0]])
    }

    @Test func aWriteSetsBothAxesAndKeepsTheLiftOffDistance() async throws {
        let fake = FakeDevice.superstrike
        let device = fake.endpoint()
        defer { device.close() }
        let caps = try await ExtendedDPI.capabilities(device)
        let reading = try await ExtendedDPI.get(device)
        try await ExtendedDPI.set(device, dpi: 1600, capabilities: caps, keeping: reading)
        #expect(fake.requests(feature: 0x2202, function: 6).map { Array($0.params.prefix(6)) } == [[0, 0x06, 0x40, 0x06, 0x40, 2]])
        #expect(try await ExtendedDPI.get(device).x == 1600 && fake.dpi == 1600)
        #expect(try await ExtendedDPI.get(device).liftOffDistance == 2)
    }

    @Test func anOnboardModeFakeAcknowledgesAWriteAndKeepsItsOwnDPI() async throws {
        let fake = FakeDevice.g305
        let device = fake.endpoint()
        defer { device.close() }
        let before = fake.dpi
        _ = try await device.call(0x2201, 3, [0, 0x0C, 0x80])
        #expect(fake.dpi == before && fake.requests(feature: 0x2201, function: 3).count == 1)
        let plain = FakeDevice.mxMaster3S
        let other = plain.endpoint()
        defer { other.close() }
        _ = try await other.call(0x2201, 3, [0, 0x0C, 0x80])
        #expect(plain.dpi == 3200)
    }
}

/// What each fixture reports, which the matrix tests in the daemon rely on.
@MainActor struct MatrixFixtureTests {
    @Test func eachFixtureHasTheKindAndFeaturesItsSourceReports() {
        let ergo = FakeDevice.mxErgo
        #expect(ergo.kind == 5 && ergo.transport.productID == 0x406F)
        #expect(Set(ergo.features.values).isSuperset(of: [0x1B04, 0x2130, 0x2205, 0x1000]))
        #expect(!ergo.features.values.contains(0x2201) && !ergo.features.values.contains(0x2121))
        let superstrike = FakeDevice.superstrike
        #expect(superstrike.features.values.contains(0x2202) && !superstrike.features.values.contains(0x2201))
        #expect(!superstrike.features.values.contains(0x1B04) && superstrike.controls.isEmpty)
        let g305 = FakeDevice.g305
        #expect(g305.features.values.contains(0x2201) && g305.features.values.contains(0x8100))
        #expect(g305.ignoresDPIWrites && g305.controls.isEmpty)
        #expect(FakeDevice.mxMaster4.features.values.contains(0x2111))
        #expect(FakeDevice.mxMaster4.control(0x01A0) != nil)
    }

    @Test func theErgoControlsCanBeDivertedPersistentlyButOnlyTheTemporaryBitIsUsed() async throws {
        let fake = FakeDevice.mxErgo
        let controls = fake.controls.filter { $0.info[4] & 0x40 != 0 }
        #expect(!controls.isEmpty && controls.allSatisfy { $0.info[4] == 0x71 || $0.info[4] == 0x31 })
        let device = fake.endpoint()
        defer { device.close() }
        try await ReprogControls.setDiverted(device, cid: 0x52, divert: true, rawXY: false)
        #expect(fake.control(0x52)?.diverted == true && fake.control(0x52)?.persistent == false)
    }
}
