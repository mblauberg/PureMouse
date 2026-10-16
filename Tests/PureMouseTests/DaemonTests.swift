import Testing
@testable import puremouse

@MainActor
struct DaemonTests {
    /// Every hand-back gets its turn before quitting gives up, within bounds.
    @Test func shutdownDeadlineCoversEveryRestoreStep() {
        #expect(Daemon.shutdownDeadline(restoreSteps: 0) == .seconds(2))
        #expect(Daemon.shutdownDeadline(restoreSteps: 6) == Session.restoreTimeout * 6 + .seconds(1))
        #expect(Daemon.shutdownDeadline(restoreSteps: 100) == .seconds(5))
    }

    /// A slot's session is retired only for a device known to differ: the first announcement
    /// after attach, for a mouse adopted before any, is that mouse reconnecting.
    @Test func newDeviceOnlyWhenTheProductChanges() {
        #expect(Daemon.isNewDevice(known: 0xB034, announced: 0xB366))  // MX Master 3S, then a keyboard
        #expect(!Daemon.isNewDevice(known: 0xB034, announced: 0xB034))
        #expect(!Daemon.isNewDevice(known: nil, announced: 0xB034))
    }
}
