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

    enum DPI: CaseIterable { case none, adjustable, extended }

    /// The rule as the issue states it, written out from the spec rather than from `Daemon.gates`:
    /// DPI of either kind adopts; else a mouse or trackball does; else, with no type, controls do.
    private static func shouldAdopt(_ kind: Kind?, controls: Bool, dpi: DPI) -> Bool {
        if dpi != .none { return true }
        guard let kind else { return controls }
        return kind == .mouse || kind == .trackball
    }

    /// A device of `kind` with the features given and nothing else the gate could read.
    private static func device(_ kind: Kind?, controls: Bool, dpi: DPI) -> FakeDevice {
        var features: [UInt8: UInt16] = [1: 0x0001, 2: 0x0003, 3: 0x0005]
        if controls { features[4] = 0x1B04 }
        switch dpi {
        case .none: break
        case .adjustable: features[5] = 0x2201
        case .extended: features[5] = 0x2202
        }
        let fake = FakeDevice(name: "Gate fixture", features: features)
        fake.transport.productID = 0xC0DE
        var info = [UInt8](repeating: 0, count: 16)
        info[1...4] = [0x12, 0x34, 0x56, 0x78]
        info[6] = 4
        info[7...8] = [0x40, 0xAA]
        fake.responses[.init(0x0003, 0)] = info
        if let kind { fake.kind = kind.rawValue } else { fake.failures[.init(0x0005, 2)] = .error(2) }
        return fake
    }

    @Test func everyTypeAndFeatureCombinationIsGatedAsTheRuleSays() async throws {
        let kinds: [Kind?] = Kind.allCases.map { $0 } + [nil]
        for kind in kinds {
            for controls in [false, true] {
                for dpi in DPI.allCases {
                    let h = try DaemonHarness("{}")
                    defer { h.close() }
                    let result = await h.tryAdopting(Self.device(kind, controls: controls, dpi: dpi))
                    let expected = Self.shouldAdopt(kind, controls: controls, dpi: dpi)
                    #expect((result == .adopted) == expected,
                            "\(kind.map { "\($0)" } ?? "no type") controls=\(controls) dpi=\(dpi) gave \(result)")
                    #expect(result == (expected ? .adopted : .notAMouse))
                }
            }
        }
    }

    @Test func aKeyboardWithOnlyExtendedDPIIsAdopted() async throws {
        // The 0x2202-only path of identification: no 0x2201 and no 0x1B04 to qualify it.
        let keyboard = Self.device(.keyboard, controls: false, dpi: .extended)
        let (h, result) = try await adopt(keyboard)
        defer { h.close() }
        #expect(result == .adopted)
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
        // Neither has DPI, so the controls rule alone decides.
        let withControls = FakeDevice.m750
        withControls.failures[.init(0x0005, 2)] = .error(2)
        withControls.features = withControls.features.filter { $0.value != 0x2201 }
        #expect(withControls.features.values.contains(0x1B04))
        let (h, result) = try await adopt(withControls)
        defer { h.close() }
        #expect(result == .adopted)

        let without = FakeDevice.m750
        without.failures[.init(0x0005, 2)] = .error(2)
        without.features = without.features.filter { ![0x1B04, 0x2201, 0x2202].contains($0.value) }
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
        #expect(h.daemon.sessions.isEmpty)
        // Awake on the retry, it answers and is adopted: the first outcome judged nothing.
        sleeping.failures[.init(0x0005, 2)] = nil
        #expect(await h.tryAdopting(sleeping) == .adopted)
    }
}
