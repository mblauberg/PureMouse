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
        try await eventually { transport.sent.count >= count }
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

    /// Longer than any test can last. A test that must end by cancel or close, never by the
    /// request's own timeout, uses it, since a timer of seconds is a race against a runner whose
    /// whole process stalls for longer (CI logs show tests spanning 10 s and more); a
    /// regression then fails by `timeLimit` instead of passing or failing by the clock.
    private static let neverTimesOut: Duration = .seconds(3600)

    @Test(.timeLimit(.minutes(1)))
    func cancellationFailsImmediatelyAndSendsQueuedRequest() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = Self.neverTimesOut
        let first = Task { try await device.request(featureIndex: 2, function: 0) }
        try await waitForSends(1, on: transport)
        let queued = Task { try await device.request(featureIndex: 3, function: 0) }
        try await eventually { device.queuedRequests == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await waitForSends(2, on: transport)
        transport.deliver(FakeTransport.reply(to: transport.sent[1], params: [42]))
        #expect(try await queued.value.first == 42)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAQueuedRequestLeavesTheQueueAtOnce() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = Self.neverTimesOut
        let owner = Task { try await device.request(featureIndex: 2, function: 0) }
        try await waitForSends(1, on: transport)
        let abandoned = Task { try await device.request(featureIndex: 3, function: 0) }
        let kept = Task { try await device.request(featureIndex: 4, function: 0) }
        try await eventually { device.queuedRequests == 2 }
        abandoned.cancel()
        // The owner is still waiting for its reply: the queued caller must not be.
        try await eventually { device.queuedRequests == 1 }
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(transport.sent.count == 1)
        transport.deliver(FakeTransport.reply(to: transport.sent[0], params: [1]))
        #expect(try await owner.value.first == 1)
        // The one behind the abandoned request still goes out, and the abandoned one never does.
        try await waitForSends(2, on: transport)
        #expect(transport.sent[1].featureIndex == 4)
        transport.deliver(FakeTransport.reply(to: transport.sent[1], params: [2]))
        #expect(try await kept.value.first == 2)
        #expect(transport.sent.count == 2 && device.queuedRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aQueuedRequestCancelledAsItIsHandedTheEndpointLeavesNothingStuck() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = Self.neverTimesOut
        let owner = Task { try await device.request(featureIndex: 2, function: 0) }
        try await waitForSends(1, on: transport)
        let queued = Task { try await device.request(featureIndex: 3, function: 0) }
        try await eventually { device.queuedRequests == 1 }
        // The reply hands the endpoint on and the cancel follows with no turn between: whichever
        // wins, the caller ends cancelled and the endpoint is free for the next request.
        transport.deliver(FakeTransport.reply(to: transport.sent[0], params: [1]))
        queued.cancel()
        _ = try await owner.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        let next = Task { try await device.request(featureIndex: 5, function: 0) }
        try await eventually { transport.sent.last?.featureIndex == 5 }
        transport.deliver(FakeTransport.reply(to: transport.sent.last!, params: [3]))
        #expect(try await next.value.first == 3)
        #expect(!transport.sent.contains { $0.featureIndex == 3 })
    }

    @Test(.timeLimit(.minutes(1)))
    func aRequestAlreadyCancelledNeverQueuesOrSends() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        defer { device.close() }
        device.timeout = Self.neverTimesOut
        let owner = Task { try await device.request(featureIndex: 2, function: 0) }
        try await waitForSends(1, on: transport)
        let doomed = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await device.request(featureIndex: 3, function: 0)
        }
        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }
        #expect(device.queuedRequests == 0 && transport.sent.count == 1)
        transport.deliver(FakeTransport.reply(to: transport.sent[0], params: [1]))
        _ = try await owner.value
    }

    @Test(.timeLimit(.minutes(1)))
    func closeFailsPendingAndQueuedWithoutSendingThem() async throws {
        let transport = FakeTransport()
        let device = HIDPPDevice(interface: transport, index: directDeviceIndex)
        // Only `close` may end the first request, however slow the runner.
        device.timeout = Self.neverTimesOut
        let first = Task { try await device.request(featureIndex: 1, function: 0) }
        try await waitForSends(1, on: transport)
        let second = Task { try await device.request(featureIndex: 2, function: 0) }
        let third = Task { try await device.request(featureIndex: 3, function: 0) }
        // Both must be queued behind the first, not stopped by `send`'s check before queueing.
        try await eventually { device.queuedRequests == 2 }
        device.close()
        #expect(device.queuedRequests == 0)
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

    @Test func deviceInfoGivesTheUnitAndModelIDs() async throws {
        let reply: [UInt8] = [4, 0x0A, 0x1B, 0x2C, 0x3D, 0, 6, 0xB0, 0x34, 0, 0, 0, 0, 0, 0, 0]
        #expect(DeviceIdentity.parseInfo(reply)
                    == .init(unitID: [0x0A, 0x1B, 0x2C, 0x3D], modelID: [0xB0, 0x34, 0, 0, 0, 0]))
        #expect(DeviceIdentity.parseInfo(Array(reply.prefix(12))) == nil)
        let fake = FakeDevice.mxMaster3S
        let device = fake.endpoint()
        defer { device.close() }
        #expect(try await DeviceIdentity.info(device).modelID == [0xB0, 0x34, 0, 0, 0, 0])
    }

    @Test func deviceTypeNamesTheKind() async throws {
        let fake = FakeDevice(features: [1: 0x0005])
        let device = fake.endpoint()
        defer { device.close() }
        #expect(try await DeviceName.kind(device) == .mouse)
        #expect(DeviceName.Kind.mouse.name == "mouse" && DeviceName.Kind.trackball.rawValue == 5)
        fake.kind = 5
        #expect(try await DeviceName.kind(device) == .trackball)
        fake.kind = 0x40
        #expect(try await DeviceName.kind(device) == nil)
        #expect(fake.requests(feature: 0x0005, function: 2).count == 3)
    }

    @Test func aProbeHeaderSetsTheProductIDAndTheM750StartsNative() {
        let m750 = FakeDevice.m750
        #expect(m750.transport.productID == 0xB02C)
        #expect(m750.controls.allSatisfy { !$0.diverted && !$0.rawXY })
        #expect(m750.control(0x00FD) != nil)
        #expect(FakeDevice.mxMaster3S.transport.productID == 0xB034)
    }
}
