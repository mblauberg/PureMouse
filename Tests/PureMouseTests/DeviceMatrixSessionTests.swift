import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// The recorded and hand-built mice (`Tests/Fixtures/probe`) taken through adoption and apply:
/// each is configured with the features it reports and no others, and nothing persistent is
/// written to any of them.
@Suite(.quietLog) @MainActor
struct DeviceMatrixSessionTests {
    static let config = #"{"dpi": 1600, "smoothScroll": {"smoothingMs": 0}, "buttons": {"middle": "toggleScrollMode"}}"#

    struct Mouse: CustomTestStringConvertible, Sendable {
        let name: String
        /// The 0x2201 and 0x2202 writes expected, and the feature of the wheel taken over.
        let dpiWrites: (adjustable: Int, extended: Int)
        let wheel: UInt16?
        var testDescription: String { name }

        @MainActor var fake: FakeDevice {
            switch name {
            case "MX Master 3S": .mxMaster3S
            case "MX Master 4": .mxMaster4
            case "MX Ergo": .mxErgo
            case "G305": .g305
            default: .superstrike
            }
        }
    }

    nonisolated static let mice = [
        Mouse(name: "MX Master 3S", dpiWrites: (1, 0), wheel: 0x2121),
        Mouse(name: "MX Master 4", dpiWrites: (1, 0), wheel: 0x2121),
        Mouse(name: "MX Ergo", dpiWrites: (0, 0), wheel: 0x2130),
        Mouse(name: "G305", dpiWrites: (1, 0), wheel: nil),
        Mouse(name: "Superstrike", dpiWrites: (0, 1), wheel: nil),
    ]

    @Test(arguments: mice)
    func eachIsConfiguredWithOnlyWhatItReports(mouse: Mouse) async throws {
        let h = try DaemonHarness(Self.config)
        defer { h.close() }
        let fake = mouse.fake
        let session = try await h.adopt(fake)

        #expect(fake.requests(feature: 0x2201, function: 3).count == mouse.dpiWrites.adjustable)
        #expect(fake.requests(feature: 0x2202, function: 6).count == mouse.dpiWrites.extended)
        #expect(fake.mainWheelDiverted == (mouse.wheel == 0x2121))
        #expect(fake.lowResWheelDiverted == (mouse.wheel == 0x2130))
        #expect(session.status.capabilities?.smoothScroll == (mouse.wheel != nil))

        // Only the temporary divert bit is ever written to a control; onboard profiles (0x8100)
        // are never touched, nor anything the mouse does not report.
        #expect(fake.controls.allSatisfy { !$0.persistent })
        #expect(fake.transport.sent.allSatisfy { fake.feature(of: $0) != 0x8100 })
        let reported = Set(fake.features.values).union([0])
        #expect(fake.transport.sent.allSatisfy { reported.contains(fake.feature(of: $0) ?? 0xFFFF) || $0.featureIndex == 0 })

        let (restoring, _) = try #require(h.daemon.quit())
        await restoring.value
        #expect(fake.controls.allSatisfy { !$0.diverted } && !fake.lowResWheelDiverted && !fake.mainWheelDiverted)
        #expect(fake.controls.allSatisfy { !$0.persistent })
    }

    @Test func theErgosControlsAreOnlyEverDivertedWithTheTemporaryBit() async throws {
        let h = try DaemonHarness(#"{"smoothScroll": {}, "buttons": {"middle": "toggleScrollMode", "back": "none"}}"#)
        defer { h.close() }
        let ergo = FakeDevice.mxErgo
        _ = try await h.adopt(ergo)
        let writes = ergo.requests(feature: 0x1B04, function: 3)
        #expect(!writes.isEmpty)
        #expect(writes.allSatisfy { $0.params[2] & 0x0C == 0 && $0.params[2] & 0x03 != 0 })
        #expect(ergo.controls.contains { $0.diverted } && ergo.controls.allSatisfy { !$0.persistent })
    }

    // MARK: DPI through 0x2202

    @Test func anExtendedDPIMouseShowsItsDPIAndStepsAndSnapsTheConfiguredValue() async throws {
        let h = try DaemonHarness(#"{"dpi": 837}"#)
        defer { h.close() }
        let fake = FakeDevice.superstrike
        let session = try await h.adopt(fake)
        #expect(fake.features.values.contains(0x2202) && !fake.features.values.contains(0x2201))
        #expect(fake.dpi == 850)  // 837 is not on the sensor's list (100...25600 by 50)
        let status = session.status
        #expect(status.dpi == 850 && status.dpiSteps.count == 511 && status.dpiSteps.first == 100)
        #expect(status.capabilities?.dpi == true)
        #expect(fake.requests(feature: 0x2202, function: 6).count == 1)
    }

    @Test func aReadbackThatDiffersMeansDPIIsNotControllableAndNothingElseIsWritten() async throws {
        let h = try DaemonHarness(#"{"dpi": 800}"#)
        defer { h.close() }
        let fake = FakeDevice.g305  // keeps its own DPI on a write, as an onboard profile does
        let log = CapturedLog()
        let session = try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let session = try await h.adopt(fake)
            try await session.apply()  // a second apply: no retry loop, no second line
            return session
        }
        #expect(fake.dpi == 1600)  // its own, unchanged
        #expect(session.status.capabilities?.dpi == false)
        #expect(fake.requests(feature: 0x2201, function: 3).count == 1)  // tried once, never again
        #expect(fake.transport.sent.allSatisfy { fake.feature(of: $0) != 0x8100 })
        #expect(log.lines.filter { $0.message.contains("cannot be set") }.count == 1)
    }

    @Test func cyclingDPIAfterARefusalWritesNothing() async throws {
        let h = try DaemonHarness(#"{"dpi": 800, "dpiPresets": [800, 2400], "buttons": {"back": "cycleDPI"}}"#)
        defer { h.close() }
        let fake = FakeDevice.mxMaster3S
        fake.ignoresDPIWrites = true  // keeps its own DPI, as an onboard profile does
        let session = try await h.adopt(fake)
        #expect(session.status.capabilities?.dpi == false)
        fake.emit(0x1B04, params: [0, 0x53])
        fake.emit(0x1B04, params: [0, 0])
        await session.deviceActions.drain()
        #expect(fake.requests(feature: 0x2201, function: 3).count == 1)
    }

    @Test func aMismatchIsNotARefusalWhileTheSupportedListIsUnknown() async throws {
        let h = try DaemonHarness(#"{"dpi": 800}"#)
        defer { h.close() }
        let fake = FakeDevice.g305
        fake.failures[.init(0x2201, 1)] = .error(2)  // the list cannot be read, so the target is sent as is
        let session = try await h.adopt(fake)
        #expect(session.status.capabilities?.dpi == true)
    }

    // MARK: Battery by voltage

    @Test func aVoltageOnlyBatteryReportsALevelWithoutAPercentage() async throws {
        let fake = FakeDevice.m750
        fake.features = fake.features.mapValues { $0 == 0x1004 ? 0x1001 : $0 }
        let h = try await SessionHarness(fake, identify: true)
        defer { h.close() }
        try await h.session.apply()
        let battery = try #require(h.session.status.battery)
        #expect(battery.percent == nil)
        #expect(h.session.status.capabilities?.battery == true)
    }
}
