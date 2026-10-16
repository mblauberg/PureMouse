import HIDPP
import Testing
@testable import puremouse

@MainActor
struct SessionActionTests {
    @Test func optionalFeatureRepliesNeverHideTransportFailures() {
        for error in [HIDPPError.timeout, .closed, .sendFailed(-1)] {
            #expect(!Session.isOptionalFeatureReplyError(error))
        }
        #expect(!Session.isOptionalFeatureReplyError(CancellationError()))
        for error in [HIDPPError.malformedResponse, .featureNotSupported(0x2111),
                      .protocol20(code: 2), .protocol10(code: 1)] {
            #expect(Session.isOptionalFeatureReplyError(error))
        }
    }

    /// Every hand-back gets its turn before quitting gives up, within bounds.
    @Test func shutdownDeadlineCoversEveryRestoreStep() {
        #expect(Daemon.shutdownDeadline(restoreSteps: 0) == .seconds(2))
        #expect(Daemon.shutdownDeadline(restoreSteps: 6) == Session.restoreTimeout * 6 + .seconds(1))
        #expect(Daemon.shutdownDeadline(restoreSteps: 6) >= Session.restoreTimeout * 6)
        #expect(Daemon.shutdownDeadline(restoreSteps: 100) == .seconds(5))
    }
}
