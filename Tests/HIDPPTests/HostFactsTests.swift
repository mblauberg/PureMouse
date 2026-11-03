import HIDPP
import HIDPPTesting
import Testing

/// The read-only wrappers behind About This Mouse: firmware (0x0003), the current Easy-Switch host
/// (0x1814) and the host list (0x1815). Nothing here changes the mouse.
@MainActor @Suite struct HostFactsTests {
    @Test func firmwareTextIsNameVersionAndBuild() {
        let reply: [UInt8] = [0, 0x52, 0x42, 0x4D, 0x22, 0x01, 0x00, 0x15, 1, 0, 0, 0, 0, 0, 0, 0]
        let firmware = DeviceIdentity.parseFirmware(reply)
        #expect(firmware == .init(kind: .firmware, name: "RBM", major: 0x22, minor: 0x01, build: 0x15))
        #expect(firmware?.text == "RBM 22.01 B0015")
        #expect(DeviceIdentity.parseFirmware([0, 0x41, 0x42, 0x43, 0x01, 0x02, 0, 0])?.text == "ABC 01.02")
        #expect(DeviceIdentity.parseFirmware([5, 0x41, 0x42, 0x43, 1, 2, 0, 0]) == nil)
        #expect(DeviceIdentity.parseFirmware([0, 0x41]) == nil)
    }

    @Test func theMainFirmwareSkipsTheBootloader() async throws {
        let fake = FakeDevice(features: [1: 0x0003])
        fake.firmware = [
            [1, 0x42, 0x4F, 0x54, 0x01, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0x52, 0x42, 0x4D, 0x22, 0x01, 0x00, 0x15, 1, 0, 0, 0, 0, 0, 0, 0],
        ]
        let device = fake.endpoint()
        defer { device.close() }
        #expect(try await DeviceIdentity.mainFirmware(device)?.text == "RBM 22.01 B0015")
        #expect(fake.hostWrites.isEmpty)
    }

    @Test func aMouseWithoutFirmwareEntitiesHasNoMainFirmware() async throws {
        let fake = FakeDevice(features: [1: 0x0003])
        let device = fake.endpoint()
        defer { device.close() }
        #expect(try await DeviceIdentity.mainFirmware(device) == nil)
    }

    @Test func changeHostReadsTheCountAndCurrentHost() async throws {
        #expect(ChangeHost.parseInfo([3, 1, 0]) == .init(count: 3, current: 1))
        #expect(ChangeHost.parseInfo([3, 3, 0]) == nil)
        #expect(ChangeHost.parseInfo([0, 0, 0]) == nil)
        let fake = FakeDevice(features: [1: 0x1814])
        fake.hosts = ["Mac", nil, nil]
        fake.currentHost = 2
        let device = fake.endpoint()
        defer { device.close() }
        #expect(try await ChangeHost.info(device) == .init(count: 3, current: 2))
        #expect(fake.requests(feature: 0x1814, function: 0).count == 1)
        #expect(fake.hostWrites.isEmpty)
    }

    @Test func hostsInfoReadsPairedStateAndNames() async throws {
        let fake = FakeDevice(features: [1: 0x1815])
        fake.hosts = ["Studio", "MacBook Air with a long name", nil]
        fake.currentHost = 1
        let device = fake.endpoint()
        defer { device.close() }
        let info = try await HostsInfo.info(device)
        #expect(info == .init(count: 3, current: 1, hasNames: true))
        let hosts = try await HostsInfo.hosts(device, info: info)
        #expect(hosts == [
            .init(index: 0, paired: true, name: "Studio"),
            .init(index: 1, paired: true, name: "MacBook Air with a long name"),
            .init(index: 2, paired: false, name: ""),
        ])
        #expect(fake.hostWrites.isEmpty)
    }

    /// The real reply is [flags, reserved, count, current] (Solaar `get_host_info`).
    @Test func hostsInfoParsesTheRealLayout() {
        #expect(HostsInfo.parseInfo([3, 0, 3, 1]) == .init(count: 3, current: 1, hasNames: true))
        #expect(HostsInfo.parseInfo([2, 0, 3, 0]) == .init(count: 3, current: 0, hasNames: false))
        #expect(HostsInfo.parseInfo([1, 0, 3, 3]) == nil)  // current past the count
        #expect(HostsInfo.parseInfo([1, 0, 0, 0]) == nil)
        #expect(HostsInfo.parseInfo([1, 0, 3]) == nil)
    }

    @Test func aMouseThatKeepsNoNamesIsNotAskedForThem() async throws {
        let fake = FakeDevice(features: [1: 0x1815])
        fake.hosts = ["Studio", "MacBook Air", nil]
        fake.hostNames = false
        let device = fake.endpoint()
        defer { device.close() }
        let info = try await HostsInfo.info(device)
        #expect(!info.hasNames)
        let hosts = try await HostsInfo.hosts(device, info: info)
        #expect(hosts == [.init(index: 0, paired: true, name: ""), .init(index: 1, paired: true, name: ""),
                          .init(index: 2, paired: false, name: "")])
        #expect(fake.requests(feature: 0x1815, function: 3).isEmpty)
    }

    @Test func aFeatureErrorSurfacesAsAnError() async {
        let fake = FakeDevice(features: [1: 0x1815])
        let device = fake.endpoint()
        defer { device.close() }
        await #expect(throws: (any Error).self) { _ = try await HostsInfo.info(device) }
    }
}
