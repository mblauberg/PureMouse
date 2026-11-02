import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// What a session publishes about its mouse: identity, capabilities and controls, all from what
/// the mouse reports.
@Suite(.quietLog) @MainActor
struct SessionStatusTests {
    typealias Capabilities = Status.Device.Capabilities

    func encoded(_ device: Status.Device) throws -> String {
        String(decoding: try Companion.encoder.encode(device), as: UTF8.self)
    }

    @Test func theMXMaster3SReportsItsIdentityAndEveryCapabilityItHas() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.responses[.init(0x0003, 0)]?.replaceSubrange(1...4, with: [0x0A, 0x1B, 0x2C, 0x3D])
        let h = try await SessionHarness(fake, identify: true)
        defer { h.close() }
        #expect(h.session.status.capabilities == nil)  // not before an apply
        try await h.session.apply()
        let status = h.session.status
        #expect(status.model == "mb03400000000")
        #expect(status.unit == "0a1b2c3d")
        #expect(status.kind == "mouse")
        // Haptics are asked about only by a haptic action, so are unknown here.
        #expect(status.capabilities == Capabilities(dpi: true, smartShift: true, smoothScroll: true, thumbWheel: true,
                                                    haptics: nil, battery: true))
        #expect(status.controls.map(\.cid) == [0x52, 0x53, 0x56, 0xC3, 0xC4])
        // The raw capture marks every divertable control (additional flags 0x05) as raw-XY capable.
        #expect(status.controls.filter { $0.gestures == true }.map(\.cid) == [0x52, 0x53, 0x56, 0xC3, 0xC4])
        #expect(status.controls.allSatisfy { $0.gestures != nil })
    }

    @Test func theM750ShowsOnlyWhatItHas() async throws {
        let h = try await SessionHarness(.m750, identify: true)
        defer { h.close() }
        try await h.session.apply()
        let status = h.session.status
        #expect(status.capabilities == Capabilities(dpi: true, smartShift: false, smoothScroll: false, thumbWheel: false,
                                                    haptics: nil, battery: true))
        // 0x0050 and 0x0051 are not divertable, 0x00D7 is virtual; the rest report raw XY.
        #expect(status.controls.map(\.cid) == [0x52, 0x53, 0x56, 0xFD])
        #expect(status.controls.allSatisfy { $0.gestures == true })
        #expect(status.kind == "mouse")
        #expect(status.model.map(Config.isDeviceKey) == true && status.model?.first == "m")
        #expect(status.unit == nil)  // the dump's 0x0003 reply carries no unit ID
    }

    @Test func aMouseWithoutSmartShiftThumbWheelOrHapticsIsDescribedByWhatItReports() async throws {
        let h = try await SessionHarness(.synthetic, identify: true)
        defer { h.close() }
        try await h.session.apply()
        let status = h.session.status
        #expect(status.model == "m40aa00000000" && status.unit == "12345678" && status.kind == "mouse")
        #expect(status.capabilities == Capabilities(dpi: true, smartShift: false, smoothScroll: true, thumbWheel: false,
                                                    haptics: nil, battery: true))
        #expect(status.controls.map(\.cid) == [0x52, 0x53, 0x56])
        #expect(status.controls.allSatisfy { $0.gestures == false })
    }

    @Test(arguments: [[UInt8](repeating: 0, count: 16), [0] + [UInt8](repeating: 0xFF, count: 15)])
    func aModelIDOfAllZerosOrAllOnesFallsBackToTheProductKey(reply: [UInt8]) async throws {
        let fake = FakeDevice.m750
        fake.responses[.init(0x0003, 0)] = reply
        let h = try await SessionHarness(fake, identify: true)
        defer { h.close() }
        #expect(h.session.deviceKey == "pb02c")
        #expect(h.session.unit == nil)
    }

    @Test func withoutDeviceInfoTheKeyIsTheProductIDAndThereIsNoUnit() async throws {
        let fake = FakeDevice.m750
        fake.features[2] = nil  // 0x0003
        let h = try await SessionHarness(fake, identify: true)
        defer { h.close() }
        #expect(h.session.deviceKey == "pb02c" && h.session.unit == nil)
        #expect(h.session.name == "Signature Plus M750" && h.session.kind == .mouse)
        try await h.session.apply()
        #expect(h.session.status.model == "pb02c")
    }

    @Test func aDeviceInfoThatTimesOutLeavesTheKeyUnknownRatherThanGuessed() async throws {
        let fake = FakeDevice.m750
        fake.failures[.init(0x0003, 0)] = .timeout
        let h = try await SessionHarness(fake, identify: true)
        defer { h.close() }
        #expect(h.session.deviceKey == nil && h.session.name == "Signature Plus M750")
    }

    /// A capability first learned after apply, here by a haptic action, is published then; one
    /// still unknown is left out of the JSON rather than written as false.
    @Test func aCapabilityLearnedAfterApplyIsPublished() async throws {
        let fake = FakeDevice.mxMaster3S  // no 0x19B0
        let h = try await SessionHarness(fake, config: SessionHarness.config(#"{"buttons": {"back": {"haptic": "knock"}}}"#))
        defer { h.close() }
        var changes = 0
        h.session.onChange = { changes += 1 }
        try await h.session.apply()
        let applied = changes
        func pressBack() async {
            fake.emit(0x1B04, params: [0, 0x53])
            fake.emit(0x1B04, params: [0, 0])
            await h.session.deviceActions.drain()
        }
        fake.dropFirstLookup(of: 0x19B0)
        await pressBack()
        #expect(fake.droppedLookups == [0x19B0])
        #expect(h.session.status.capabilities?.haptics == nil && h.session.status.capabilities?.dpi == true)
        #expect(changes == applied)
        let unknown = try encoded(h.session.status)
        #expect(!unknown.contains("haptics") && unknown.contains("\"smartShift\" : true"))
        await pressBack()
        #expect(h.session.status.capabilities?.haptics == false)
        #expect(changes == applied + 1)
    }

    @Test func aMouseWithOnlyTheFallbackFeaturesHasThoseCapabilities() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.features[0x0E] = 0x2111  // Enhanced SmartShift in place of 0x2110
        fake.features[0x08] = 0x1000  // legacy battery in place of 0x1004
        let h = try await SessionHarness(fake)
        defer { h.close() }
        try await h.session.apply()
        let capabilities = try #require(h.session.status.capabilities)
        #expect(capabilities.smartShift == true && capabilities.battery == true)
    }

    @Test func aFallbackLookupThatFailsLeavesThatCapabilityOutNotFalse() async throws {
        let fake = FakeDevice.mxMaster3S
        fake.features[0x08] = nil  // no 0x1004, so 0x1000 is looked up
        fake.dropFirstLookup(of: 0x1000)
        let h = try await SessionHarness(fake)
        defer { h.close() }
        try await h.session.apply()
        #expect(fake.droppedLookups == [0x1000])
        #expect(h.device.knownPresence(of: 0x1004) == false)
        let capabilities = try #require(h.session.status.capabilities)
        #expect(capabilities.battery == nil && capabilities.smartShift == true)
    }

    @Test func buildingCapabilitiesSendsNothing() async throws {
        let h = try await SessionHarness(.m750, identify: true)
        defer { h.close() }
        try await h.session.apply()
        h.fake.transport.sent.removeAll()
        _ = try encoded(h.session.status)
        #expect(h.fake.transport.sent.isEmpty)
    }

    @Test func capabilitiesAreInheritedByAReplacementSession() async throws {
        let h = try await SessionHarness(.m750)
        defer { h.close() }
        try await h.session.apply()
        let replacement = h.replacement()
        defer { replacement.close() }
        #expect(replacement.status.capabilities == h.session.status.capabilities)
    }

    @Test func theM750WithSmoothScrollingSendsNoWheelWriteAndSaysWhyOnce() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {}}"#), identify: true)
            defer { h.close() }
            try await h.session.apply()
            try await h.session.apply()
            #expect(h.session.status.capabilities?.smoothScroll == false)
            // Every request went to a feature the mouse has, so none to 0x2121 or 0x2150. A request
            // for one it lacks never reaches the wire (the index lookup fails first), so a wheel
            // write attempted anyway shows as `apply` throwing, above.
            #expect(!h.fake.transport.sent.isEmpty)
            #expect(h.fake.transport.sent.allSatisfy { h.fake.feature(of: $0).map { ![0x2121, 0x2150].contains($0) } ?? false })
            // Nothing was taken over, so quitting has no wheel to hand back.
            #expect(!h.session.wheelsMayBeDiverted)
            #expect(Daemon.restoreSteps(quitting: [h.session.restoreSteps], pausing: []) == h.session.divertedControls.count)
        }
        let line = "Signature Plus M750: \(Session.smoothScrollUnsupported)"
        #expect(log.lines.filter { $0.level == "info" && $0.message == line }.count == 1)
        #expect(!log.lines.contains { $0.level == "error" })
    }

    @Test func withoutAccessibilityAMouseWithNoWheelsLogsNoWheelError() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try await SessionHarness(.m750, config: SessionHarness.config(#"{"smoothScroll": {}}"#),
                                             environment: .init(canPostEvents: false))
            defer { h.close() }
            try await h.session.apply()
            try await h.session.apply()
        }
        #expect(!log.lines.contains { $0.message.contains("no Accessibility permission") })
    }

    @Test func aMouseWithoutSmartShiftThumbWheelOrHapticsIsConfiguredQuietly() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let config = try SessionHarness.config(#"""
                {"dpi": 1650, "scrollWheel": {"mode": "freespin", "smartShiftThreshold": 255},
                 "thumbWheel": {"action": "tabs"}, "smoothScroll": {},
                 "buttons": {"gesture": {"up": "missionControl"}, "top": "showDesktop",
                             "middle": "toggleScrollMode", "back": {"haptic": "knock"}}}
                """#)
            let h = try await SessionHarness(.synthetic, config: config, identify: true)
            defer { h.close() }
            try await h.session.apply()
            try await h.session.apply()
            // Only what it has: its DPI, its main wheel and its buttons.
            #expect(h.fake.dpi == 1650)
            #expect(h.fake.mainWheelDiverted)
            #expect(Set(h.fake.controls.filter(\.diverted).map(\.cid)) == [0x52, 0x53])
            #expect(h.fake.transport.sent.allSatisfy { h.fake.feature(of: $0) != nil })
        }
        #expect(log.lines.filter { $0.level != "debug" }.isEmpty, "\(log.lines)")
        // The gesture and top buttons it lacks: one debug line.
        #expect(log.lines.filter { $0.message.contains("missing or not divertable") }.count == 1)
    }
}
