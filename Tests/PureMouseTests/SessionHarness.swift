import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@MainActor
struct SessionHarness {
    let fake: FakeDevice
    let device: HIDPPDevice
    let session: Session

    /// `identify` reads the fake's identity as adoption does (`Identification.read`) and gives the
    /// session the config resolved for it (`Config.forDevice`).
    init(_ fake: FakeDevice = .mxMaster3S, config: Config = .empty,
         inheriting inherited: Session.Inherited = .init(),
         environment: SessionEnvironment = .init(canPostEvents: true, configureRetryDelay: .milliseconds(1)),
         identify: Bool = false) async throws {
        self.fake = fake
        device = fake.endpoint()
        device.timeout = .milliseconds(100)
        let controls = try await ReprogControls.controls(device)
        let identity = identify
            ? await Identification.read(device, productID: UInt16(exactly: fake.transport.productID)) : Identification()
        session = Session(device: device, name: fake.name, identity: identity, id: "fake", controls: controls,
                          config: config.forDevice(identity.deviceKey), inheriting: inherited, environment: environment)
    }

    /// A session taking over from `session` on the same endpoint, as a reload makes one: by
    /// default with what `session` hands down now.
    func replacement(config: Config = .empty, inheriting inherited: Session.Inherited? = nil,
                     environment: SessionEnvironment = .init(canPostEvents: true)) -> Session {
        Session(device: device, name: fake.name, identity: session.identity, id: "replacement",
                controls: Array(session.controls.values), config: config.forDevice(session.deviceKey),
                inheriting: inherited ?? session.inheritance, environment: environment)
    }

    static func config(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    static func example() throws -> Config {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Config.load(from: root.appendingPathComponent("config.example.json"))
    }

    func close() {
        session.close()
        device.close()
    }
}

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
        let endpoint = daemon.listen(fake.transport, index: fake.index)
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

extension FakeDevice {
    /// No real mouse: a model ID, buttons, adjustable DPI, a high-resolution wheel and a battery,
    /// but no SmartShift, thumb wheel or haptics; for showing a mouse is configured with only
    /// what it reports.
    static var synthetic: FakeDevice {
        let fake = FakeDevice(name: "Synthetic mouse",
                              features: [1: 0x0001, 2: 0x0003, 3: 0x0005, 4: 0x1B04, 5: 0x2201, 6: 0x2121, 7: 0x1004])
        fake.transport.productID = 0xC0DE
        fake.controls = [0x0050, 0x0051].map { FakeDevice.Control(cid: $0, flags: 0, additionalFlags: 0) }
            + [0x0052, 0x0053, 0x0056].map { FakeDevice.Control(cid: $0, additionalFlags: 0) }
        var info = [UInt8](repeating: 0, count: 16)
        info[1...4] = [0x12, 0x34, 0x56, 0x78]
        info[6] = 4  // wireless
        info[7...8] = [0x40, 0xAA]
        fake.responses[.init(0x0003, 0)] = info
        return fake
    }
}

/// Captures run on whichever task logs; the lock also permits simultaneous test captures.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Log.Line] = []
    var lines: [Log.Line] { lock.withLock { storage } }
    func append(_ line: Log.Line) { lock.withLock { storage.append(line) } }
}

/// Drops the lines a suite's tests log instead of writing them to the runner's stderr. A test that
/// reads its lines sets its own `.lines` output inside, which wins for that task tree.
struct QuietLog: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        try await Log.$testOutput.withValue(.lines { _ in }) { try await function() }
    }
}

extension Trait where Self == QuietLog {
    static var quietLog: Self { Self() }
}
