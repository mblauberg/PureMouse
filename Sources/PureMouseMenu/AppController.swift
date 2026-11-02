import AppKit
import PureMouseAppSupport
import PureMouseKit

/// The app delegate: owns the model and the status item. Settings is an app of its own
/// (`SettingsLauncher`), so this process never holds a window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    /// Whether this run shows its icon, decided once: notifications run only then.
    private static let iconShown = Locations.live.showsInMenuBar
    let model = AppModel(alert: Alerts.show, notifications: notifications(iconShown: iconShown))
    private var statusMenu: StatusMenu?
    private var lowBatteryNotificationsOn = true

    /// The low-battery notification callbacks: none for a run with its icon hidden, which then
    /// neither announces nor consumes a band (`BatteryAlertStore`).
    static func notifications(iconShown: Bool) -> (announce: AppModel.Announce, withdraw: AppModel.Withdraw)? {
        iconShown ? (Notifier.post, Notifier.removeDelivered) : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lowBatteryNotificationsOn = model.lowBatteryNotificationsOn
        Task { await Notifier.refresh() }
        model.statusChanged = { [weak self] in self?.statusChanged() }
        model.startWatching()
        if Self.iconShown { statusMenu = StatusMenu(model: model, app: self) }
        // Opened by hand, or asked for Settings while starting (`puremouse` opened from the Finder
        // restarts this agent, then opens it), or with no icon to show: open Settings. With no
        // icon there is nothing left to do once it is open.
        let request = ShowRequest.consume()
        if !Locations.launchedByLaunchd || statusMenu == nil || request != nil {
            showSettings(pane: request?.pane) { [weak self] in
                if self?.statusMenu == nil { NSApp.terminate(nil) }
            }
        }
        #if DEBUG || DEVHOOKS
        DevHooks.run(app: self)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelCapture()
        model.flush()
    }

    func showSettings(pane: SettingsPane? = nil, then done: @escaping @MainActor () -> Void = {}) {
        Task { await Notifier.refresh() }
        SettingsLauncher.shared.open(pane: pane, then: done)
    }

    private func statusChanged() {
        statusMenu?.updateIcon()
        // macOS asks per app, and this app posts the notifications: when the switch is turned on
        // in Settings (another app), ask for permission here.
        let on = model.lowBatteryNotificationsOn
        if Self.iconShown, NotificationPermission.shouldRequest(wasOn: lowBatteryNotificationsOn, isOn: on) {
            Task { await Notifier.requestIfNeeded() }
        }
        lowBatteryNotificationsOn = on
    }

    // MARK: Lifecycle

    /// Quit PureMouse: quits Settings (and one still opening), then stops the daemon (which
    /// restores the mouse) and this app. Both start again at login. `stop` boots out this app's
    /// agent too, so launchd may end us first.
    func quitAll() {
        SettingsLauncher.shared.quit { [model] in
            model.flush()
            guard Locations.live.daemon != nil else { NSApp.terminate(nil); return }
            Lifecycle.run(.stop) { result in
                if case .failure(let error) = result {
                    Alerts.show("PureMouse could not stop", error.description)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Hide Menu Bar Icon: removes the menu app's login agent, which ends this app; the daemon
    /// keeps running.
    func hideMenuBarIcon() {
        model.flush()
        model.perform(.menuOff) { [self] in
            statusMenu?.remove()
            statusMenu = nil
            NSApp.terminate(nil)
        }
    }

    #if DEBUG || DEVHOOKS
    func openMenuForTesting(appearance: NSAppearance?) { statusMenu?.open(appearance: appearance) }
    func closeMenuForTesting() { statusMenu?.close() }
    #endif

    func openPrivacy(_ pane: PrivacyPane) {
        NSWorkspace.shared.open(pane.url)
    }

    func openReleases() {
        NSWorkspace.shared.open(Links.releases)
    }
}
