import HIDPP
import HIDPPTesting
import Testing

@MainActor
struct HIDPPDeviceTests {
    @Test func pingClassifiesLegacySlotsAndModernVersions() async {
        let fake = FakeDevice()
        fake.transport.timing = .synchronous
        let device = fake.endpoint()
        defer { device.close() }
        device.timeout = .milliseconds(10)
        fake.ping = .hidpp10(1)
        #expect(await device.ping() == .hidpp10)
        for code: UInt8 in [8, 9] {
            fake.ping = .hidpp10(code)
            #expect(await device.ping() == .noAnswer)
        }
        fake.ping = .silent
        #expect(await device.ping() == .noAnswer)
        fake.ping = .hidpp20(4, 5)
        #expect(await device.ping() == .hidpp20(major: 4, minor: 5))
    }

    @Test func absentFeatureIsLookedUpOnlyOnce() async throws {
        let fake = FakeDevice()
        let device = fake.endpoint()
        defer { device.close() }
        #expect(device.knownPresence(of: 0x2121) == nil)
        #expect(try await !device.hasFeature(0x2121))
        #expect(device.knownPresence(of: 0x2121) == false)
        #expect(try await !device.hasFeature(0x2121))
        #expect(fake.transport.sent.count == 1)
        #expect(device.feature(at: 0) == 0)
    }

    @Test func timeoutAndErrorsNeverCacheAbsence() async throws {
        let fake = FakeDevice(features: [1: 0x2121])
        let device = fake.endpoint()
        defer { device.close() }
        device.timeout = .milliseconds(10)
        fake.failures[.init(0, 0)] = .timeout
        await #expect(throws: HIDPPError.timeout) { try await device.hasFeature(0x2121) }
        #expect(device.knownPresence(of: 0x2121) == nil)
        device.timeout = .seconds(1)
        fake.failures[.init(0, 0)] = .error(2)
        await #expect(throws: HIDPPError.protocol20(code: 2)) { try await device.hasFeature(0x2121) }
        #expect(device.knownPresence(of: 0x2121) == nil)
        fake.failures.removeAll()
        #expect(try await device.hasFeature(0x2121))
        #expect(device.knownPresence(of: 0x2121) == true)
        #expect(fake.transport.sent.count == 3)
        #expect(try await device.hasFeature(0x2121))
        #expect(fake.transport.sent.count == 3)
    }

    private func waitForSends(_ count: Int, on transport: FakeTransport) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.sent.count < count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(transport.sent.count >= count)
        try #require(transport.sent.count >= count)
    }

    @Test func lateReplyDoesNotCompleteNextRequest() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = .milliseconds(20)
        await #expect(throws: HIDPPError.timeout) { try await device.request(featureIndex: 3, function: 0) }
        let old = try #require(transport.sent.first)
        device.timeout = .seconds(2)
        let next = Task { try await device.request(featureIndex: 3, function: 0) }
        try await waitForSends(2, on: transport)
        let new = transport.sent[1]
        #expect(old.softwareID != new.softwareID)
        transport.deliver(FakeTransport.reply(to: old, params: [11]))
        transport.deliver(FakeTransport.reply(to: new, params: [22]))
        #expect(try await next.value.first == 22)
    }

    @Test func cancellationFailsImmediatelyAndSendsQueuedRequest() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = .seconds(10)
        let first = Task { try await device.request(featureIndex: 2, function: 0) }
        try await waitForSends(1, on: transport)
        let queued = Task { try await device.request(featureIndex: 3, function: 0) }
        await Task.yield()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await waitForSends(2, on: transport)
        transport.deliver(FakeTransport.reply(to: transport.sent[1], params: [42]))
        #expect(try await queued.value.first == 42)
    }

    @Test func closeFailsPendingAndQueuedWithoutSendingThem() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        let first = Task { try await device.request(featureIndex: 1, function: 0) }
        try await waitForSends(1, on: transport)
        let second = Task { try await device.request(featureIndex: 2, function: 0) }
        let third = Task { try await device.request(featureIndex: 3, function: 0) }
        await Task.yield()
        device.close()
        for task in [first, second, third] {
            await #expect(throws: HIDPPError.closed) { try await task.value }
        }
        #expect(transport.sent.count == 1)
    }

    @Test func routesOnlyEventsAndShortLegacyNotifications() {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        var events: [Report] = []
        device.onEvent = { events.append($0) }
        transport.deliver(Report(deviceIndex: directDeviceIndex, featureIndex: 0x41, function: 0, softwareID: 3))
        #expect(events.isEmpty)
        let notification = Report(reportID: .short, deviceIndex: directDeviceIndex,
                                  featureIndex: 0x41, function: 0, softwareID: 3)
        transport.deliver(notification)
        let event = Report(deviceIndex: directDeviceIndex, featureIndex: 7, function: 0, softwareID: 0)
        transport.deliver(event)
        #expect(events == [notification, event])
    }

    @Test func synchronousRepliesAndSoftwareIDRanges() async throws {
        for range: ClosedRange<UInt8> in [0x8...0xF, 0x2...0x7] {
            let transport = FakeTransport()
            transport.timing = .synchronous
            transport.answer = { FakeTransport.reply(to: $0, params: [99]) }
            let device = HIDPPDevice(interface: transport, index: directDeviceIndex, softwareIDs: range)
            for _ in 0..<range.count + 1 {
                #expect(try await device.request(featureIndex: 2, function: 0).first == 99)
            }
            #expect(transport.sent.map(\.softwareID) == Array(range) + [range.lowerBound])
            device.close()
        }
    }
}
