import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@MainActor
struct DaemonTests {
    /// A new install has no config file, and that means the default set: not an error, and the
    /// file is not created. Removing the file later returns to the defaults the same way.
    @Test func aMissingConfigFileIsTheDefaultSetNotAnError() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "puremouse-none-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let daemon = Daemon(configURL: url, environment: SessionEnvironment(canPostEvents: true))
        #expect(daemon.status(running: true).config.error == nil)
        daemon.reload()
        #expect(daemon.status(running: true).config.error == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try Data("{".utf8).write(to: url)
        daemon.reload()
        #expect(daemon.status(running: true).config.error != nil)
        try FileManager.default.removeItem(at: url)
        daemon.reload()
        #expect(daemon.status(running: true).config.error == nil)
    }

    @Test func legacyPingIsIgnoredAndSilenceRetried() {
        #expect(Daemon.adoption(for: .hidpp10) == .notAMouse)
        #expect(Daemon.adoption(for: .noAnswer) == .noAnswer)
        #expect(Daemon.adoption(for: .hidpp20(major: 1, minor: 0)) == .notAMouse)
        #expect(Daemon.adoption(for: .hidpp20(major: 4, minor: 5)) == nil)
    }

    /// Every hand-back gets its turn before quitting gives up, within bounds.
    @Test func shutdownDeadlineCoversEveryRestoreStep() {
        #expect(Daemon.shutdownDeadline(restoreSteps: 0) == .seconds(2))
        #expect(Daemon.shutdownDeadline(restoreSteps: 6) == Session.restoreTimeout * 6 + .seconds(1))
        #expect(Daemon.shutdownDeadline(restoreSteps: 100) == .seconds(5))
    }

    /// Quitting right after a pause still waits for the paused mice: their restores count, one
    /// pause after another, against the mice restored side by side on quit.
    @Test func quittingCountsRestoresStillPausing() {
        #expect(Daemon.restoreSteps(quitting: [], pausing: []) == 0)
        #expect(Daemon.restoreSteps(quitting: [], pausing: [7]) == 7)
        #expect(Daemon.restoreSteps(quitting: [2, 5], pausing: []) == 5)
        #expect(Daemon.restoreSteps(quitting: [3], pausing: [4, 2]) == 6)
        #expect(Daemon.shutdownDeadline(restoreSteps: Daemon.restoreSteps(quitting: [], pausing: [7]))
                    == Session.restoreTimeout * 7 + .seconds(1))
    }

    /// A slot's session is retired only for a device known to differ: the first announcement
    /// after attach, for a mouse adopted before any, is that mouse reconnecting.
    @Test func newDeviceOnlyWhenTheProductChanges() {
        #expect(Daemon.isNewDevice(known: 0xB034, announced: 0xB366))  // MX Master 3S, then a keyboard
        #expect(!Daemon.isNewDevice(known: 0xB034, announced: 0xB034))
        #expect(!Daemon.isNewDevice(known: nil, announced: 0xB034))
    }

    /// The permission poll runs only for what is needed now: a receiver-only setup never waits on
    /// Input Monitoring, nor a config that posts nothing on Accessibility.
    @Test func permissionsNeededNow() {
        #expect(Permissions.needed(postsEvents: false, bluetooth: false, hidOpenFailed: false) == [])
        #expect(Permissions.needed(postsEvents: true, bluetooth: false, hidOpenFailed: false) == .accessibility)
        #expect(Permissions.needed(postsEvents: false, bluetooth: true, hidOpenFailed: false) == .inputMonitoring)
        #expect(Permissions.needed(postsEvents: false, bluetooth: false, hidOpenFailed: true) == .inputMonitoring)
        #expect(Permissions.needed(postsEvents: true, bluetooth: true, hidOpenFailed: false) == .all)
    }

    /// A Bluetooth mouse the daemon has seen but cannot ask anything without Input Monitoring is in
    /// the status as waiting for it, and the daemon says it needs that permission. Once allowed,
    /// nothing waits.
    @Test func aBluetoothMouseWithoutInputMonitoringIsListedAsWaitingForIt() throws {
        let h = try DaemonHarness("{}", permissions: .accessibility)
        defer { h.close() }
        #expect(h.daemon.status(running: true).waiting.isEmpty)
        let mouse = FakeDevice.mxMaster3S
        _ = h.daemon.listen(mouse.transport, index: mouse.index)
        let status = h.daemon.status(running: true)
        #expect(status.waiting.map(\.name) == [mouse.transport.product])
        #expect(status.permissions.inputMonitoring == false)
        #expect(h.daemon.missingPermissions == .inputMonitoring)
        // Not while PureMouse is quitting: the final status lists nothing.
        #expect(h.daemon.status(running: false).waiting.isEmpty)

        let allowed = try DaemonHarness("{}", permissions: .all)
        defer { allowed.close() }
        let other = FakeDevice.mxMaster3S
        _ = allowed.daemon.listen(other.transport, index: other.index)
        #expect(allowed.daemon.status(running: true).waiting.isEmpty)
        #expect(allowed.daemon.missingPermissions.isEmpty)
    }

    /// Logi Options+ is looked up again as the daemon reloads (as it does at wake, on a control
    /// change and at each permission check), so the status follows it starting and stopping.
    @Test func theStatusFollowsLogiOptionsStartingAndStoppingAtTheNextRecheck() throws {
        final class Processes: @unchecked Sendable { var names: [String] = [] }
        let processes = Processes()
        let h = try DaemonHarness("{}", logiOptions: { processes.names })
        defer { h.close() }
        h.daemon.recheckLogiOptions()
        #expect(!h.daemon.status(running: true).logiOptionsRunning)

        processes.names = ["logioptionsplus_agent"]
        #expect(!h.daemon.status(running: true).logiOptionsRunning, "nothing looks until a moment comes")
        h.daemon.reload()
        #expect(h.daemon.status(running: true).logiOptionsRunning)

        processes.names = []
        h.daemon.reload()
        #expect(!h.daemon.status(running: true).logiOptionsRunning)
    }

    /// The first look is at start, so a status written then already says so.
    @Test func logiOptionsAlreadyRunningIsInTheFirstStatus() throws {
        let h = try DaemonHarness("{}", logiOptions: { ["logioptionsplus_agent"] })
        defer { h.close() }
        h.daemon.recheckLogiOptions()
        #expect(h.daemon.status(running: true).logiOptionsRunning)
    }

    /// A keyboard on Bluetooth is not worth asking Input Monitoring for.
    @Test func aBluetoothKeyboardNeitherWaitsNorNeedsInputMonitoring() throws {
        #expect(Daemon.mayBeMouse(product: "MX Master 3S"))
        #expect(Daemon.mayBeMouse(product: "M750"))
        #expect(!Daemon.mayBeMouse(product: "MX Keys S"))
        #expect(!Daemon.mayBeMouse(product: "Logitech Keyboard K380"))
        let h = try DaemonHarness("{}", permissions: .accessibility)
        defer { h.close() }
        let keyboard = FakeTransport(product: "MX Keys")
        _ = h.daemon.listen(keyboard, index: directDeviceIndex)
        #expect(h.daemon.status(running: true).waiting.isEmpty)
        #expect(h.daemon.missingPermissions.isEmpty)
    }

    /// With a receiver mouse only, the daemon asks for Accessibility and never for Input
    /// Monitoring, which only Bluetooth needs.
    @Test func aReceiverMouseAsksForAccessibilityOnly() async throws {
        let h = try DaemonHarness("{}", permissions: [])
        defer { h.close() }
        let m750 = FakeDevice.m750
        m750.onReceiver(slot: 2)
        _ = h.daemon.listen(m750.transport, index: m750.index)
        #expect(h.daemon.missingPermissions == .accessibility)
        #expect(h.daemon.status(running: true).waiting.isEmpty)
    }

    func config(_ json: String) throws -> Config { try SessionHarness.config(json) }

    /// Accessibility is needed when any device entry, not only the top level, posts events.
    @Test func aDeviceEntryThatPostsEventsNeedsAccessibility() throws {
        #expect(!Daemon.postsEvents(SessionHarness.nothing))
        #expect(!Daemon.postsEvents(try config("""
            {"smoothScroll": {"enabled": false}, "buttons": {"back": "default", "forward": "default", "gesture": "default"},
             "devices": {"pb02c": {"dpi": 800}}}
            """)))
        #expect(Daemon.postsEvents(.defaults))
        #expect(Daemon.postsEvents(try config(#"{"devices": {"pb02c": {"smoothScroll": {}}}}"#)))
        #expect(Daemon.postsEvents(try config(#"{"devices": {"pb02c": {"buttons": {"back": "none"}}}}"#)))
        #expect(Daemon.postsEvents(try config(#"{"devices": {"pb02c": {"thumbWheel": {"action": "tabs"}}}}"#)))
    }

    /// A reload keeps a mouse's live DPI unless its own resolved dpi or dpiPresets changed.
    @Test func liveDPIIsKeptUnlessThatMousesDPIChanged() throws {
        func keeps(_ before: Config, _ after: Config, _ key: String?) -> Bool {
            Daemon.keepsLiveDPI(before.forDevice(key), after.forDevice(key))
        }
        let before = try config(#"{"dpi": 1600, "devices": {"pb02c": {"dpi": 1200}}}"#)
        let otherEntry = try config(#"{"dpi": 1600, "devices": {"pb02c": {"dpi": 1000}}}"#)
        #expect(!keeps(before, otherEntry, "pb02c"))
        #expect(keeps(before, otherEntry, "mb03400000000"))
        #expect(keeps(before, otherEntry, nil))
        let topLevel = try config(#"{"dpi": 1400, "devices": {"pb02c": {"dpi": 1200}}}"#)
        #expect(keeps(before, topLevel, "pb02c"))
        #expect(!keeps(before, topLevel, nil))
        let presets = try config(#"{"dpi": 1600, "devices": {"pb02c": {"dpi": 1200, "dpiPresets": [800]}}}"#)
        #expect(!keeps(before, presets, "pb02c"))
    }
}
