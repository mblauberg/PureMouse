import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

/// Without permission to post events (Accessibility), a control whose action would post one stays
/// native: diverting it would only lose the button. Device-only actions still divert.
@Suite(.quietLog) @MainActor
struct SessionPermissionTests {
    private static let denied = SessionEnvironment(canPostEvents: false, configureRetryDelay: .milliseconds(1))

    private func applied(_ json: String, canPostEvents: Bool = false) async throws -> SessionHarness {
        var environment = Self.denied
        environment.canPostEvents = canPostEvents
        let h = try await SessionHarness(config: SessionHarness.config(json), environment: environment)
        try await h.session.apply()
        return h
    }

    private func diverted(_ h: SessionHarness, _ cids: [UInt16]) -> [Bool] {
        cids.map { h.fake.control($0)?.diverted == true }
    }

    @Test func postedActionsStayNativeWithoutAccessibility() async throws {
        let h = try await applied(#"""
            {"buttons": {"back": "navigateBack", "forward": {"keys": "cmd+]"}, "middle": "mute"}}
            """#)
        defer { h.close() }
        #expect(diverted(h, [0x53, 0x56, 0x52]) == [false, false, false])
        #expect(h.fake.controlWrites(cid: 0x53).isEmpty && h.session.divertedControls.isEmpty)
    }

    @Test func deviceOnlyActionsStillDivertWithoutAccessibility() async throws {
        let h = try await applied(#"""
            {"dpiPresets": [800, 1600], "buttons": {"back": "cycleDPI", "forward": "toggleScrollMode",
             "middle": "none"}}
            """#)
        defer { h.close() }
        #expect(diverted(h, [0x53, 0x56, 0x52]) == [true, true, true])
    }

    @Test func aGestureNeedsAnActionItCanPerformToDivertAndTakeRawMotion() async throws {
        let posted = try await applied(#"{"buttons": {"gesture": {"click": "mute", "up": "missionControl"}}}"#)
        defer { posted.close() }
        #expect(posted.fake.control(0xC3)?.diverted == false && posted.fake.control(0xC3)?.rawXY == false)
        let mixed = try await applied(#"{"buttons": {"gesture": {"click": "cycleDPI", "up": "missionControl"}}}"#)
        defer { mixed.close() }
        #expect(mixed.fake.control(0xC3)?.diverted == true && mixed.fake.control(0xC3)?.rawXY == true)
    }

    @Test func anAppsDefaultClickDoesNotDivertWhatNoScopeCanPerform() async throws {
        let h = try await applied(#"""
            {"buttons": {"back": "navigateBack"},
             "apps": {"com.example.a": {"buttons": {"back": "default"}}}}
            """#)
        defer { h.close() }
        #expect(h.fake.control(0x53)?.diverted == false)
    }

    @Test func aControlSomeScopeCanPerformIsDivertedWhateverTheOthersNeed() async throws {
        let h = try await applied(#"""
            {"buttons": {"back": "navigateBack", "forward": "navigateForward"},
             "apps": {"com.example.a": {"buttons": {"back": "cycleDPI"}}}}
            """#)
        defer { h.close() }
        #expect(diverted(h, [0x53, 0x56]) == [true, false])
    }

    @Test func theNextApplyWithPermissionDivertsAsBefore() async throws {
        let json = #"""
            {"buttons": {"back": "navigateBack", "gesture": {"up": "missionControl"}}}
            """#
        let h = try await applied(json)
        defer { h.close() }
        #expect(diverted(h, [0x53, 0xC3]) == [false, false])
        h.session.close()
        let granted = h.replacement(config: try SessionHarness.config(json),
                                    environment: .init(canPostEvents: true, configureRetryDelay: .milliseconds(1)))
        defer { granted.close() }
        try await granted.apply()
        #expect(diverted(h, [0x53, 0xC3]) == [true, true] && h.fake.control(0xC3)?.rawXY == true)
    }

    @Test func aDeniedSessionSaysWhatItLeavesNativeOnce() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            // The default set's own bindings are set aside (forward, the gesture, smooth scrolling) so
            // the line is about the two buttons named here.
            let h = try await applied(#"""
                {"smoothScroll": {"enabled": false},
                 "buttons": {"back": "navigateBack", "middle": "cycleDPI", "forward": "default", "gesture": "default"}}
                """#)
            defer { h.close() }
            try await h.session.apply()
        }
        let lines = log.lines.filter { $0.message.contains("no Accessibility permission") }
        // Back (0x0053) posts a swipe; the middle button's cycleDPI needs no permission.
        #expect(lines.count == 1 && lines.allSatisfy { $0.message.contains("0x0053") && !$0.message.contains("0x0052") })
    }
}
