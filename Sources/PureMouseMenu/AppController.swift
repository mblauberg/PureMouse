import AppKit
import PureMouseKit
import notify

/// The app delegate: owns the model, the status item and (only while open) the Settings window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController? { NSApp.delegate as? AppController }

    let model = AppModel()
    private var statusMenu: StatusMenu?
    private var settings: SettingsWindowController?
    private var showToken: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(app: self)
        model.statusChanged = { [weak self] in self?.statusMenu?.updateIcon() }
        model.startWatching()
        // A second launch (the Finder, `open`) asks this one to show Settings, then exits.
        notify_register_dispatch(Companion.showSettingsNotification, &showToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = ShowRequest.consume() // answered now
                self?.showSettings()
            }
        }
        if Paths.showsInMenuBar { statusMenu = StatusMenu(model: model, app: self) }
        // A request posted while this instance was still starting (opening the app from the
        // Finder restarts the menu agent, then opens it) counts too. Consumed either way.
        let requested = ShowRequest.consume()
        if !Paths.launchedByLaunchd || statusMenu == nil || requested { showSettings() }
        #if DEBUG
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

    // MARK: Settings

    func showSettings(pane: SettingsPane? = nil) {
        if settings == nil {
            settings = SettingsWindowController(model: model, app: self)
        }
        settings?.show(pane: pane)
    }

    /// Releases the window and its view tree. With no menu bar icon there is nothing left to do.
    func settingsDidClose() {
        settings = nil
        model.cancelCapture()
        model.flush()
        if pendingMenuOff {
            // Removing the menu agent ends this process, so it waits until Settings closes.
            pendingMenuOff = false
            Lifecycle.run(.menuOff) { _ in NSApp.terminate(nil) }
        } else if statusMenu == nil {
            NSApp.terminate(nil)
        } else {
            relaunchPending = true
            // After the window's close animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + Relaunch.delay(launchedAt: launchedAt)) { [weak self] in self?.relaunchIfIdle() }
        }
    }

    private var relaunchPending = false
    private let launchedAt = ProcessInfo.processInfo.systemUptime

    /// Settings leaves tens of MB behind in AppKit and SwiftUI caches, so once it has closed, this
    /// process starts over as a fresh copy (`Relaunch`). It waits while Settings is open again, the
    /// menu is open or a lifecycle command runs; whichever of those ends last tries again.
    func relaunchIfIdle() {
        guard relaunchPending, settings == nil, let statusMenu, !statusMenu.isOpen, Lifecycle.idle,
              !pendingMenuOff, NSApp.modalWindow == nil else { return }
        // However it was reached (the menu closing, a command ending), not before launchd would
        // restart it at once.
        let wait = Relaunch.delay(launchedAt: launchedAt)
        if wait > 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.relaunchIfIdle() }
            return
        }
        relaunchPending = false
        model.flush()
        Relaunch.now()
        malloc_zone_pressure_relief(nil, 0) // a development copy, or the agent is gone
    }

    var settingsWindow: NSWindow? { settings?.window }

    /// Fits Settings to its pane once a change in the pane's height has laid out (`SettingsTabs.refit`).
    func refitSettings() {
        DispatchQueue.main.async { [weak self] in
            (self?.settingsWindow?.contentViewController as? SettingsTabs)?.refit()
        }
    }

    // MARK: Lifecycle

    /// Quit PureMouse: stops the daemon (which restores the mouse) and this app. Both start again
    /// at login. `stop` boots out this app's agent too, so launchd may end us first.
    func quitAll() {
        model.flush()
        guard Paths.daemon != nil else { NSApp.terminate(nil); return }
        Lifecycle.run(.stop) { result in
            if case .failure(let error) = result {
                Alerts.show("PureMouse could not stop", error.description)
            }
            NSApp.terminate(nil)
        }
    }

    /// Hide Menu Bar Icon: removes the menu app's login agent; the daemon keeps running.
    func hideMenuBarIcon() {
        model.flush()
        Lifecycle.perform(.menuOff) { [self] in
            setShowsInMenuBar(false)
        }
    }

    /// Shows or removes the status item in this process (the agent change is already made).
    func setShowsInMenuBar(_ shown: Bool) {
        if shown, statusMenu == nil {
            statusMenu = StatusMenu(model: model, app: self)
        } else if !shown, let statusMenu {
            statusMenu.remove()
            self.statusMenu = nil
            if settings == nil { NSApp.terminate(nil) }
        }
    }

    var showsStatusItem: Bool { statusMenu != nil }

    #if DEBUG
    func openMenuForTesting(appearance: NSAppearance?) { statusMenu?.open(appearance: appearance) }
    #endif

    private var pendingMenuOff = false

    /// Settings' "Show in menu bar". Hiding removes the icon now and the menu agent when Settings
    /// closes (removing the agent ends this process). Showing writes and boots the agent.
    func setMenuBarPreference(_ shown: Bool) {
        if !shown {
            statusMenu?.remove()
            statusMenu = nil
            pendingMenuOff = true
        } else if pendingMenuOff {
            pendingMenuOff = false
            setShowsInMenuBar(true)
        } else if !Paths.showsInMenuBar {
            Lifecycle.perform(.menuOn) { [self] in setShowsInMenuBar(true) }
        } else {
            setShowsInMenuBar(true)
        }
    }

    enum Privacy: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    func openPrivacy(_ pane: Privacy) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openReleases() {
        NSWorkspace.shared.open(Links.releases)
    }
}

/// "Show Settings", from a second launch to the running instance: a notification, plus a file
/// stamped with its time, so an instance still starting up (and not yet listening) sees it too.
enum ShowRequest {
    private static var file: URL { Companion.showSettingsURL }

    static func post() {
        try? FileManager.default.createDirectory(at: Companion.directory, withIntermediateDirectories: true)
        try? Data().write(to: file)
        notify_post(Companion.showSettingsNotification)
    }

    /// Whether one was posted in the last few seconds; removes it either way.
    static func consume() -> Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return false }
        try? FileManager.default.removeItem(at: file)
        return -date.timeIntervalSinceNow < 5
    }
}

enum Links {
    static let repository = URL(string: "https://github.com/mblauberg/PureMouse")!
    static let releases = URL(string: "https://github.com/mblauberg/PureMouse/releases")!
    static let licence = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/LICENSE")!
    static let logiOptions = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/docs/troubleshooting.md#logi-options")!
}
