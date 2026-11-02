import AppKit
import PureMouseAppSupport
import PureMouseKit
import PureMouseSettingsUI
import notify

/// The helper's delegate: shows the Settings window at launch, on the pane a `ShowRequest` names
/// (else the last one shown), and quits when it closes. Config edits are saved, and a select by
/// pressing still listening is cancelled, however the app ends.
@MainActor
final class SettingsApp: NSObject, NSApplicationDelegate, SettingsHost {
    private let model = AppModel(alert: Alerts.show)
    private var settings: SettingsWindowController?
    private var showToken: Int32 = -1
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        terminateSignal = Self.terminateOnSIGTERM()
        model.startWatching()
        // Asked again while open (the menu bar app posts, then opens this app): the pane is in
        // the file.
        notify_register_dispatch(Companion.showSettingsNotification, &showToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(ShowRequest.consume()?.pane) }
        }
        settings = SettingsWindowController(model: model, host: self)
        show(ShowRequest.consume()?.pane)
        #if DEBUG
        DevHooks.run { [weak self] in self?.show($0) }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelCapture()
        model.flush()
    }

    private func show(_ pane: SettingsPane?) {
        settings?.show(pane: pane)
    }

    /// `kill`, `pkill` and a development menu app's `Process.terminate()` send SIGTERM, which
    /// would end the process without `applicationWillTerminate`.
    private static func terminateOnSIGTERM() -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        return source
    }

    // MARK: SettingsHost

    var showsStatusItem: Bool { model.locations.showsInMenuBar }

    /// Runs `menu on` or `off` now. This app is not in the menu agent's process group, so removing
    /// that agent leaves it open.
    func setMenuBarPreference(_ shown: Bool) {
        guard shown != model.locations.showsInMenuBar else { return }
        model.flush()
        model.perform(shown ? .menuOn : .menuOff)
    }

    func settingsDidClose() {
        NSApp.terminate(nil)
    }

    /// The menu bar app posts the notifications, and macOS asks per app, so it asks for itself
    /// (when it sees the setting turned on); this app can neither ask for it nor read its answer.
    func requestNotifications() async {}

    func notificationsAllowed() async -> Bool? { nil }
}
