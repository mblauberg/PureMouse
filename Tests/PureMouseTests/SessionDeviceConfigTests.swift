import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// A daemon on a config file of its own, adopting fakes as it adopts mice.
@MainActor
final class DaemonHarness {
    let url: URL
    let daemon: Daemon
    private var endpoints: [HIDPPDevice] = []

    init(_ json: String) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "puremouse-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        daemon = Daemon(configURL: url, environment: .init(canPostEvents: true, configureRetryDelay: .milliseconds(1)))
    }

    /// Adopts `fake` and waits for its first configure to end.
    func adopt(_ fake: FakeDevice) async throws -> Session {
        let endpoint = daemon.listen(fake.transport, index: directDeviceIndex)
        endpoint.timeout = .milliseconds(100)
        endpoints.append(endpoint)
        #expect(await daemon.adopt(endpoint) == .adopted)
        return try await settled(fake)
    }

    /// The session for `fake` once it has finished configuring.
    func settled(_ fake: FakeDevice) async throws -> Session {
        var session: Session?
        try await eventually {
            session = daemon.sessions.values.first { $0.device.interface === fake.transport }
            return session.map { !$0.isConfiguring } ?? false
        }
        return try #require(session)
    }

    /// Rewrites the config file and reloads, as a save does.
    func reload(_ json: String? = nil) throws {
        if let json { try Data(json.utf8).write(to: url) }
        daemon.reload()
    }

    func close() {
        daemon.sessions.values.forEach { $0.close() }
        endpoints.forEach { $0.close() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Each mouse gets the settings resolved for its device key, and requests can aim at one.
@Suite(.quietLog) @MainActor
struct SessionDeviceConfigTests {
    static let m1 = "mb03440910000"  // the MX Master 3S fixture
    static let m2 = "m40aa00000000"  // the synthetic mouse

    @Test func eachMouseGetsItsOwnDPIAndUseConfiguredDPICanAimAtOne() async throws {
        let h = try DaemonHarness(#"""
            {"dpi": 1600, "dpiPresets": [800, 2400], "buttons": {"back": "cycleDPI"},
             "devices": {"\#(Self.m1)": {"dpi": 1200}}}
            """#)
        defer { h.close() }
        let mx = FakeDevice.mxMaster3S, other = FakeDevice.synthetic
        let s1 = try await h.adopt(mx), s2 = try await h.adopt(other)
        #expect(s1.model == Self.m1 && s2.model == Self.m2)
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

    @Test(arguments: [true, false])
    func aMouseWithoutDPIIsAdoptedForAControlOnlyADeviceEntryBinds(bound: Bool) async throws {
        let h = try DaemonHarness(bound ? #"{"devices": {"\#(Self.m2)": {"buttons": {"back": "none"}}}}"# : "{}")
        defer { h.close() }
        let fake = FakeDevice.synthetic
        fake.features[5] = nil  // 0x2201
        let endpoint = h.daemon.listen(fake.transport, index: directDeviceIndex)
        endpoint.timeout = .milliseconds(100)
        defer { endpoint.close() }
        #expect(await h.daemon.adopt(endpoint) == (bound ? .adopted : .notAMouse))
    }

    @Test func theM750WithTheExampleConfigLogsNoErrorsAcrossReloads() async throws {
        let example = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../config.example.json").standardized, encoding: .utf8)
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let h = try DaemonHarness(example)
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
        // The gesture and top buttons it lacks: one debug line per session, nothing louder.
        let lacking = log.lines.filter { $0.message.contains("0x00c3") && $0.message.contains("not divertable") }
        #expect(lacking.count == 3 && lacking.allSatisfy { $0.level == "debug" })
    }

    @Test(arguments: [true, false])
    func theM750sKeyFollowsDeviceInfoAndItsEntryApplies(hasDeviceInfo: Bool) async throws {
        let h = try DaemonHarness(#"{"dpi": 1600}"#)
        defer { h.close() }
        let m750 = FakeDevice.m750
        if !hasDeviceInfo { m750.features[2] = nil }
        let session = try await h.adopt(m750)
        let key = try #require(session.model)
        #expect(hasDeviceInfo ? key.first == "m" : key == "pb02c")
        #expect(session.unit == nil && m750.dpi == 1600)
        try h.reload(#"{"dpi": 1600, "devices": {"\#(key)": {"dpi": 800}}}"#)
        _ = try await h.settled(m750)
        #expect(m750.dpi == 800)
        #expect(h.daemon.status(running: true).devices.first?.model == key)
    }

    @Test func toggleScrollModeWithoutSmartShiftSendsNothingAndSaysSoOncePerSession() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let config = try SessionHarness.config(#"{"buttons": {"middle": "toggleScrollMode"}}"#)
            let h = try await SessionHarness(.m750, config: config)
            defer { h.close() }
            try await h.session.apply()
            let controls = try await ReprogControls.controls(h.device)
            let replacement = Session(device: h.device, name: h.fake.name, id: "r", controls: controls, config: config,
                                      inheriting: h.session.inheritance)
            defer { replacement.close() }
            h.fake.transport.sent.removeAll()
            for session in [h.session, h.session, replacement, replacement] {
                h.device.onEvent = { [weak session] in session?.handle($0) }
                h.fake.emit(0x1B04, params: [0, 0x52])
                h.fake.emit(0x1B04, params: [0, 0])
                await session.deviceActions.drain()
            }
            #expect(h.fake.transport.sent.isEmpty)
        }
        let lines = log.lines.filter { $0.message.contains("toggleScrollMode needs SmartShift") }
        #expect(lines.count == 2 && lines.allSatisfy { $0.level == "info" })
    }
}
