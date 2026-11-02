import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// Each mouse gets the settings resolved for its device key, and requests can aim at one.
@Suite(.quietLog) @MainActor
struct SessionDeviceConfigTests {
    static let m1 = "mb03400000000"  // the MX Master 3S fixture
    static let m2 = "m40aa00000000"  // the synthetic mouse

    @Test func eachMouseGetsItsOwnDPIAndUseConfiguredDPICanAimAtOne() async throws {
        let h = try DaemonHarness(#"""
            {"dpi": 1600, "dpiPresets": [800, 2400], "buttons": {"back": "cycleDPI"},
             "devices": {"\#(Self.m1)": {"dpi": 1200}}}
            """#)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S, other = FakeDevice.synthetic
        let s1 = try await h.adopt(mx), s2 = try await h.adopt(other)
        #expect(s1.deviceKey == Self.m1 && s2.deviceKey == Self.m2)
        #expect(mx.dpi == 1200 && other.dpi == 1600)
        for (fake, session) in [(mx, s1), (other, s2)] {
            fake.emit(0x1B04, params: [0, 0x53])
            fake.emit(0x1B04, params: [0, 0])
            await session.deviceActions.drain()
        }
        #expect(mx.dpi == 2400 && other.dpi == 2400)
        h.daemon.handle(Control(useConfiguredDPI: 1, device: Self.m1.uppercased()))  // matched without case
        await s1.deviceActions.drain()
        await s2.deviceActions.drain()
        #expect(mx.dpi == 1200 && s1.state.liveDPI == nil)
        #expect(other.dpi == 2400 && s2.state.liveDPI == 2400)
    }

    @Test func aReloadChangingOneDevicesDPIKeepsTheOthersLiveDPI() async throws {
        let config = #"{"dpi": 1600, "dpiPresets": [800, 2400], "buttons": {"back": "cycleDPI"}, "devices": {"\#(Self.m1)": {"dpi": %d}}}"#
        let h = try DaemonHarness(String(format: config, 1200))
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S, other = FakeDevice.synthetic
        let s1 = try await h.adopt(mx), s2 = try await h.adopt(other)
        for (fake, session) in [(mx, s1), (other, s2)] {
            fake.emit(0x1B04, params: [0, 0x53])
            fake.emit(0x1B04, params: [0, 0])
            await session.deviceActions.drain()
        }
        try h.reload(String(format: config, 1000))
        let r1 = try await h.settled(mx), r2 = try await h.settled(other)
        #expect(r1 !== s1 && r2 !== s2)
        #expect(mx.dpi == 1000 && r1.state.liveDPI == nil)
        #expect(other.dpi == 2400 && r2.state.liveDPI == 2400)
    }

    @Test(arguments: [true, false])
    func captureAimedAtOneMouseDivertsOnlyItsControls(aimed: Bool) async throws {
        let h = try DaemonHarness("{}")
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S, other = FakeDevice.synthetic
        let s1 = try await h.adopt(mx), s2 = try await h.adopt(other)
        h.daemon.handle(Control(capture: .init(token: 1, device: aimed ? Self.m1 : nil)))
        await s1.diversion.drain()
        await s2.diversion.drain()
        #expect(mx.control(0x53)?.diverted == true)
        #expect(other.control(0x53)?.diverted == !aimed)
        mx.emit(0x1B04, params: [0, 0x53])
        let capture = try #require(h.daemon.status(running: true).capture)
        #expect(capture.state == .pressed && capture.cid == 0x53 && capture.model == Self.m1)
        await s1.diversion.drain()
        await s2.diversion.drain()
        #expect(mx.controls.allSatisfy { !$0.diverted } && other.controls.allSatisfy { !$0.diverted })
    }

    @Test func aMouseAdoptedDuringAnAimedCaptureJoinsOnlyIfItMatches() async throws {
        let h = try DaemonHarness("{}")
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S
        _ = try await h.adopt(mx)
        h.daemon.handle(Control(capture: .init(token: 1, device: Self.m1)))
        let other = FakeDevice.synthetic
        let s2 = try await h.adopt(other)
        await s2.diversion.drain()
        #expect(s2.capturing == nil && !other.controls.contains { $0.diverted })
    }

    @Test func theM750LogsNoErrorsAcrossReloadsAndItsSnappedDPIOnce() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try DaemonHarness(#"{"dpi": 1650, "buttons": {"gesture": {"up": "missionControl"}, "top": "showDesktop"}}"#)
            defer { h.close() }
            let m750 = FakeDevice.m750
            _ = try await h.adopt(m750)
            for _ in 1...2 {
                try h.reload()
                _ = try await h.settled(m750)
            }
            #expect(m750.dpi == 1600)
        }
        #expect(!log.lines.contains { $0.level == "error" }, "\(log.lines.filter { $0.level == "error" })")
        #expect(log.lines.filter { $0.message.hasSuffix("dpi 1650 is not supported; using 1600") }.count == 1)
    }

    /// A receiver mouse found before its slot was announced, and keyed by its product (no
    /// 0x0003), gets its key and that key's settings when the announcement names the product;
    /// one with a model ID keeps its key and session.
    @Test(arguments: [false, true])
    func aReceiverMouseKeyedByProductGetsItsKeyWhenItsSlotIsAnnounced(hasDeviceInfo: Bool) async throws {
        let h = try DaemonHarness(#"{"dpi": 1600, "devices": {"pb02c": {"dpi": 800}}}"#)
        defer { h.close() }
        let m750 = FakeDevice.m750
        if !hasDeviceInfo { m750.features[2] = nil }  // 0x0003
        m750.onReceiver(slot: 2)
        let session = try await h.adopt(m750)
        #expect(hasDeviceInfo ? session.deviceKey?.first == "m" : session.deviceKey == nil)
        #expect(m750.dpi == 1600)
        m750.announce(product: 0xB02C)
        let current = try await h.settled(m750)
        if hasDeviceInfo {
            #expect(current === session && m750.dpi == 1600)
        } else {
            #expect(current !== session && current.deviceKey == "pb02c" && m750.dpi == 800)
            #expect(h.daemon.status(running: true).devices.map(\.model) == ["pb02c"])
        }
    }

    /// An M750 keyed by nothing yet, adopted on a receiver slot: the top level diverts forward,
    /// while its product's entry (`pb02c`) would also divert back and set 800 DPI.
    private func unkeyedReceiverM750() async throws -> (DaemonHarness, FakeDevice, Session) {
        let h = try DaemonHarness(#"""
            {"buttons": {"forward": "navigateForward"},
             "devices": {"pb02c": {"dpi": 800, "buttons": {"back": "navigateBack"}}}}
            """#)
        let m750 = FakeDevice.m750
        m750.features[2] = nil  // 0x0003
        m750.onReceiver(slot: 2)
        let session = try await h.adopt(m750)
        #expect(session.deviceKey == nil && m750.control(0x56)?.diverted == true)
        return (h, m750, session)
    }

    /// The writes `fake` gets over a while, for showing none follow a restore.
    private func writes(to fake: FakeDevice, over wait: Duration = .milliseconds(100)) async throws -> Int {
        let before = fake.transport.sent.count
        try await Task.sleep(for: wait)
        return fake.transport.sent.count - before
    }

    /// An announcement between quitting's snapshot of the sessions and their restore neither
    /// replaces nor configures the session: the restore reaches the mouse and nothing follows it.
    @Test func anAnnouncementWhileQuittingLeavesTheSessionToItsRestore() async throws {
        let (h, m750, session) = try await unkeyedReceiverM750()
        defer { h.close() }
        let (restoring, _) = try #require(h.daemon.quit())
        m750.announce(product: 0xB02C)
        await restoring.value
        #expect(try await writes(to: m750) == 0)
        #expect(h.daemon.sessions.count == 1 && h.daemon.sessions.values.first === session)
        #expect(m750.control(0x56)?.diverted == false && m750.control(0x53)?.diverted == false)
        #expect(m750.dpi != 800)
    }

    /// The same while paused: the session has already been dropped, and no new one is adopted.
    @Test func anAnnouncementWhilePausedAdoptsNothing() async throws {
        let (h, m750, _) = try await unkeyedReceiverM750()
        defer { h.close() }
        h.daemon.handle(Control(paused: true))
        m750.announce(product: 0xB02C)
        try await eventually { m750.control(0x56)?.diverted == false }
        #expect(try await writes(to: m750) == 0)
        #expect(h.daemon.sessions.isEmpty)
        #expect(m750.control(0x53)?.diverted == false && m750.dpi != 800)
    }

    @Test(arguments: [true, false])
    func theM750sKeyFollowsDeviceInfoAndItsEntryApplies(hasDeviceInfo: Bool) async throws {
        let h = try DaemonHarness(#"{"dpi": 1600}"#)
        defer { h.close() }
        let m750 = FakeDevice.m750
        if !hasDeviceInfo { m750.features[2] = nil }
        let session = try await h.adopt(m750)
        let key = try #require(session.deviceKey)
        #expect(hasDeviceInfo ? key.first == "m" : key == "pb02c")
        #expect(session.unit == nil && m750.dpi == 1600)
        try h.reload(#"{"dpi": 1600, "devices": {"\#(key)": {"dpi": 800}}}"#)
        _ = try await h.settled(m750)
        #expect(m750.dpi == 800)
        #expect(h.daemon.status(running: true).devices.first?.model == key)
    }
}
