import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// A report at feature index 0x41 is a receiver's connection notification only in its HID++ 1.0
/// framing; anywhere else it is the feature at that index (`Receiver.isConnectionNotification`).
@Suite(.quietLog) @MainActor
struct EventRoutingTests {
    /// A direct mouse whose feature table puts the unified battery at index 0x41.
    private func mouseWithBatteryAt0x41() -> FakeDevice {
        let fake = FakeDevice.synthetic
        fake.features[7] = nil
        fake.features[0x41] = 0x1004
        return fake
    }

    @Test func aDirectDevicesLongEventAtIndex41ReachesItsFeature() async throws {
        let h = try await SessionHarness(mouseWithBatteryAt0x41())
        defer { h.close() }
        try await h.session.apply()
        h.fake.transport.sent.removeAll()
        // 0x10 as the first byte would read as "link up" and 0x4B as "link down" to the classifier
        // that mistook this for a notification: both must update the battery instead.
        for percent: UInt8 in [0x4B, 0x10] {
            h.fake.emit(0x1004, params: [percent, 4, 0, 0])
            #expect(h.session.status.battery?.percent == Int(percent))
        }
        #expect(h.session.status.online)
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }

    @Test func aReceiverSlotsLongEventAtIndex41ReachesItsFeatureToo() async throws {
        let fake = mouseWithBatteryAt0x41()
        fake.onReceiver(slot: 2)
        let h = try await SessionHarness(fake)
        defer { h.close() }
        try await h.session.apply()
        h.fake.transport.sent.removeAll()
        h.fake.emit(0x1004, params: [0x10, 4, 0, 0])
        #expect(h.session.status.battery?.percent == 0x10)
        #expect(!h.session.isConfiguring && h.fake.transport.sent.isEmpty)
    }

    @Test func aReceiversShortNotificationStillTakesTheLinkUpAndDown() async throws {
        let fake = FakeDevice.m750
        fake.onReceiver(slot: 2)
        let h = try await SessionHarness(fake)
        defer { h.close() }
        try await h.session.apply()
        fake.announce(product: 0xB02C, linked: false)
        #expect(!h.session.status.online)
        fake.announce(product: 0xB02C, linked: true)
        try await eventually { h.session.status.online && !h.session.isConfiguring }
    }

    /// The daemon's listener for a slot with no session uses the same classifier.
    @Test func anUnadoptedSlotHearsOnlyTheShortNotification() async throws {
        let h = try DaemonHarness("{}")
        defer { h.close() }
        let fake = FakeDevice.m750
        fake.onReceiver(slot: 2)
        _ = h.daemon.listen(fake.transport, index: 2)
        // A long event at index 0x41 whose first byte reads as link up must not start an adoption.
        fake.transport.deliver(Report(deviceIndex: 2, featureIndex: 0x41, function: 0, softwareID: 0,
                                      params: [0x10, 0x2C, 0xB0]))
        for _ in 0..<200 { await Task.yield() }
        #expect(fake.transport.sent.isEmpty)
        fake.announce(product: 0xB02C)
        try await eventually { !fake.transport.sent.isEmpty }
    }
}
