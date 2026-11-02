import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// Which devices PureMouse takes on, whatever the config binds: the type decides, DPI always
/// qualifies, and a device that does not say what it is must at least list controls.
@Suite(.quietLog) @MainActor
struct AdoptionGateTests {
    typealias Kind = DeviceName.Kind

    @Test(arguments: [
        (Kind.mouse, false, false, true), (.mouse, true, true, true),
        (.trackball, true, false, true), (.trackball, false, false, true),
        (nil, true, false, true), (nil, false, false, false), (nil, false, true, true),
        (.keyboard, true, false, false), (.keyboard, true, true, true),
        (.numpad, true, false, false), (.presenter, true, false, false), (.remote, true, false, false),
        (.receiver, true, false, false), (.touchpad, true, false, false),
    ] as [(Kind?, Bool, Bool, Bool)])
    func theGateFollowsTypeThenDPIThenControls(kind: Kind?, hasControls: Bool, hasDPI: Bool, adopted: Bool) {
        #expect(Daemon.gates(kind: kind, hasControls: hasControls, hasDPI: hasDPI) == adopted)
    }

    private func adopt(_ fake: FakeDevice, config: String = "{}") async throws -> (DaemonHarness, Daemon.Adoption) {
        let h = try DaemonHarness(config)
        return (h, await h.tryAdopting(fake))
    }

    @Test func aMouseWithNothingBoundIsStillAdopted() async throws {
        let (h, result) = try await adopt(.m750)
        defer { h.close() }
        #expect(result == .adopted)
    }

    @Test func aMouseWithNeitherControlsNorDPIIsAdopted() async throws {
        let fake = FakeDevice.g305
        fake.features = fake.features.filter { $0.value != 0x2201 }
        let (h, result) = try await adopt(fake)
        defer { h.close() }
        #expect(result == .adopted)
    }

    @Test func aKeyboardIsRefusedWhateverTheConfigBindsAndIsAskedNothingMore() async throws {
        let keyboard = FakeDevice.m750
        keyboard.kind = Kind.keyboard.rawValue
        keyboard.features = keyboard.features.filter { $0.value != 0x2201 }
        let (h, result) = try await adopt(keyboard, config: #"{"buttons": {"middle": "toggleScrollMode"}, "dpi": 1600}"#)
        defer { h.close() }
        #expect(result == .notAMouse)
        #expect(keyboard.transport.sent.allSatisfy { keyboard.feature(of: $0) != 0x1B04 })  // no control list read
        #expect(h.daemon.sessions.isEmpty)
    }

    @Test func aKeyboardWithAdjustableDPIIsAdopted() async throws {
        let keyboard = FakeDevice.m750
        keyboard.kind = Kind.keyboard.rawValue
        let (h, result) = try await adopt(keyboard)
        defer { h.close() }
        #expect(result == .adopted)
    }

    @Test func aDeviceThatAnswersNoTypeIsJudgedByItsControls() async throws {
        let withControls = FakeDevice.m750
        withControls.failures[.init(0x0005, 2)] = .error(2)
        let (h, result) = try await adopt(withControls)
        defer { h.close() }
        #expect(result == .adopted)

        let without = FakeDevice.m750
        without.failures[.init(0x0005, 2)] = .error(2)
        without.features = without.features.filter { ![0x1B04, 0x2201].contains($0.value) }
        let (h2, result2) = try await adopt(without)
        defer { h2.close() }
        #expect(result2 == .notAMouse)
    }

    @Test func aDeviceThatDoesNotAnswerTheTypeIsRetriedNotJudged() async throws {
        let sleeping = FakeDevice.m750
        sleeping.failures[.init(0x0005, 2)] = .timeout
        sleeping.features = sleeping.features.filter { $0.value != 0x2201 }
        let (h, result) = try await adopt(sleeping)
        defer { h.close() }
        #expect(result == .noAnswer)
    }
}
