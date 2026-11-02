import HIDPP
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
}
