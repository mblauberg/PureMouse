import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@Suite(.quietLog) @MainActor
struct SessionActionTests {
    @Test func optionalFeatureRepliesNeverHideTransportFailures() {
        for error in [HIDPPError.timeout, .closed, .sendFailed(-1)] {
            #expect(!error.isDeviceAnswer)
        }
        for error in [HIDPPError.malformedResponse, .featureNotSupported(0x2111),
                      .protocol20(code: 2), .protocol10(code: 1)] {
            #expect(error.isDeviceAnswer)
        }
    }

    @Test func toggleScrollModeWithoutSmartShiftSendsNothingAndSaysSoOncePerSession() async throws {
        let log = CapturedLog()
        try await Log.$testOutput.withValue(.lines { log.append($0) }) {
            let config = try SessionHarness.config(#"{"buttons": {"middle": "toggleScrollMode"}}"#)
            let h = try await SessionHarness(.m750, config: config)
            defer { h.close() }
            try await h.session.apply()
            let replacement = h.replacement(config: config)
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
