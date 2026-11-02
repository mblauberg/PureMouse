import HIDPP
import HIDPPTesting
import Testing
@testable import puremouse

@MainActor
struct ProbeTests {
    @Test func zeroFeaturesPrintsAnEmptyList() async {
        let fake = FakeDevice(features: [1: 0x0001])
        fake.responses[.init(0x0001, 0)] = [0]
        let device = fake.endpoint(softwareIDs: 0x2...0x7)
        defer { device.close() }
        var lines: [String] = []
        await Probe.dump(device) { lines.append($0) }
        #expect(lines.contains("  features: "))
        #expect(fake.requests(feature: 0x0001, function: 1).isEmpty)
    }

    @Test func zeroControlsPrintsHeaderWithoutControls() async {
        let fake = FakeDevice(features: [1: 0x0001, 2: 0x1B04])
        let device = fake.endpoint(softwareIDs: 0x2...0x7)
        defer { device.close() }
        var lines: [String] = []
        await Probe.dump(device) { lines.append($0) }
        #expect(lines.contains("  controls (0x1B04 getCidInfo / getCidReporting):"))
        #expect(!lines.contains { $0.contains("cid=") })
        #expect(!fake.transport.sent.contains { fake.feature(of: $0) == 0x1B04 && $0.function != 0 })
    }
}
