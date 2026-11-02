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

    init(_ fake: FakeDevice = .mxMaster3S, config: Config = .empty,
         inheriting inherited: Session.Inherited = .init(),
         environment: SessionEnvironment = .init(canPostEvents: true, configureRetryDelay: .milliseconds(1))) async throws {
        self.fake = fake
        device = fake.endpoint()
        device.timeout = .milliseconds(100)
        let controls = try await ReprogControls.controls(device)
        session = Session(device: device, name: fake.name, id: "fake", controls: controls,
                          config: config, inheriting: inherited, environment: environment)
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
