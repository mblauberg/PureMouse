import AppKit
import PureMouseAppSupport
import PureMouseKit

/// What the daily update check runs on: the live ones are the system's scheduler, the network, the
/// clock and the notification centre; a test passes its own, so nothing reaches GitHub.
struct UpdateSetup {
    var preferences: UpdatePreferences
    var current: String = Locations.version
    var fetcher: UpdateCheck.Fetcher = UpdateCheck.urlSession
    var now: @MainActor () -> Date = { Date() }
    var scheduler: UpdateScheduling
    /// Asks the question; true for Check Automatically.
    var ask: @MainActor () -> Bool
    var announce: @MainActor (UpdateOffer) -> Void

    // Installing what the check found: asked for by the person, never by the schedule.
    var install: @Sendable (UpdateCheck.Release, String, URL?) async -> UpdateInstallOutcome = {
        await UpdateInstaller.live.install($0, current: $1, installedApp: $2)
    }
    /// The PureMouse.app this process belongs to; nil for a development build.
    var installedApp: URL? = Locations.live.installedApp
    /// The alert behind the menu row; true to go ahead.
    var confirm: @MainActor (UpdateOffer) -> Bool = Alerts.confirmUpdate
    /// Opens the installed app the way double-clicking it does, after quitting Settings; true if
    /// it was accepted.
    var relaunch: @MainActor (URL) async -> Bool = UpdateSetup.relaunchLive
    var openPage: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    var alert: @MainActor (String, String) -> Void = Alerts.show

    @MainActor static var live: UpdateSetup {
        UpdateSetup(preferences: UpdatePreferences(.standard),
                    scheduler: BackgroundActivity(identifier: Companion.menuLabel + ".update-check"),
                    ask: Alerts.askAboutUpdates, announce: { Notifier.post($0) })
    }

    @MainActor static func relaunchLive(_ app: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            SettingsLauncher.shared.quit { continuation.resume(returning: UpdateRelaunch.open(app)) }
        }
    }
}

/// The app delegate: owns the model and the status item. Settings is an app of its own
/// (`SettingsLauncher`), so this process never holds a window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let model: AppModel
    /// Whether this run shows its icon: notifications run only then. A hidden-icon run gets no
    /// notification callbacks, so it neither announces nor consumes a band (`BatteryAlertStore`),
    /// and never asks for permission.
    private let iconShown: Bool
    private let requestPermission: @MainActor () -> Void
    private var statusMenu: StatusMenu?
    private var lowBatteryNotificationsOn: Bool
    /// The daily update check and its reminders; runs only while the icon is shown.
    let updates: UpdateReminders
    private let askAboutUpdates: @MainActor () -> Bool
    private var questionSettled = false
    private let install: @Sendable (UpdateCheck.Release, String, URL?) async -> UpdateInstallOutcome
    private let installedApp: URL?
    private let current: String
    private let confirmUpdate: @MainActor (UpdateOffer) -> Bool
    private let relaunch: @MainActor (URL) async -> Bool
    private let openPage: @MainActor (URL) -> Void
    private let terminate: @MainActor () -> Void
    private let alert: @MainActor (String, String) -> Void
    /// Where an update chosen from the menu stands; the menu shows it.
    private(set) var installState = UpdateInstallState.idle

    /// The defaults are the live app; a test passes a sandbox and spies for what reaches the
    /// notification centre.
    init(locations: Locations = .live,
         iconShown: Bool = Locations.live.showsInMenuBar,
         announce: @escaping AppModel.Announce = Notifier.post,
         withdraw: @escaping AppModel.Withdraw = Notifier.removeDelivered,
         requestPermission: @escaping @MainActor () -> Void = { Task { await Notifier.requestIfNeeded() } },
         updates setup: UpdateSetup = .live) {
        model = AppModel(locations: locations, alert: Alerts.show,
                         notifications: iconShown ? (announce, withdraw) : nil)
        self.iconShown = iconShown
        self.requestPermission = requestPermission
        lowBatteryNotificationsOn = model.lowBatteryNotificationsOn
        updates = UpdateReminders(preferences: setup.preferences, current: setup.current, fetcher: setup.fetcher,
                                  now: setup.now, scheduler: setup.scheduler, announce: setup.announce,
                                  withdraw: { withdraw([$0]) })
        askAboutUpdates = setup.ask
        install = setup.install
        installedApp = setup.installedApp
        current = setup.current
        confirmUpdate = setup.confirm
        relaunch = setup.relaunch
        openPage = setup.openPage
        terminate = setup.terminate
        alert = setup.alert
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The notification centre's delegate must be set before launching ends, or the click that
        // launched the app (a reminder, with the app not running) is lost.
        Notifier.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Notifier.refresh() }
        model.statusChanged = { [weak self] in self?.statusChanged() }
        model.startWatching()
        if iconShown { statusMenu = StatusMenu(model: model, app: self) }
        startUpdates()
        // Opened by hand, or asked for Settings while starting (`puremouse` opened from the Finder
        // restarts this agent, then opens it), or with no icon to show: open Settings. With no
        // icon there is nothing left to do once it is open.
        let request = ShowRequest.consume()
        if !Locations.launchedByLaunchd || statusMenu == nil || request != nil {
            showSettings(request) { [weak self] in
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

    func showSettings(_ request: ShowRequest? = nil, then done: @escaping @MainActor () -> Void = {}) {
        Task { await Notifier.refresh() }
        SettingsLauncher.shared.open(request ?? ShowRequest(), then: done)
    }

    func statusChanged() {
        statusMenu?.updateIcon()
        // macOS asks per app, and this app posts the notifications: when the switch is turned on
        // in Settings (another app), ask for permission here.
        let on = model.lowBatteryNotificationsOn
        if iconShown, NotificationPermission.shouldRequest(wasOn: lowBatteryNotificationsOn, isOn: on) {
            requestPermission()
        }
        lowBatteryNotificationsOn = on
        askAboutUpdatesIfDue()
    }

    // MARK: Updates

    /// Counts this launch, starts the schedule if automatic checks are on, and asks the question if
    /// it is due. A run without the icon does none of it: it ends when Settings closes.
    func startUpdates() {
        guard iconShown else { return }
        updates.noteLaunch()
        updates.start()
        askAboutUpdatesIfDue()
    }

    /// The question is asked once: on the second launch or a later one, when permissions are set up
    /// (the daemon is running and nothing it needs is missing). It waits for a status from a running
    /// daemon, which a login may write after this app starts (the file may still be the last run's,
    /// saying it stopped), and judges the permissions on that one. An alert, not a notification,
    /// since it needs an answer; the reminders that follow take no focus.
    private func askAboutUpdatesIfDue() {
        guard iconShown, !questionSettled, updates.questionDue, model.status != nil, model.daemonRunning else { return }
        questionSettled = true
        let permissionsSetUp = !model.accessibilityMissing && !(model.inputMonitoringMissing && model.hasBluetoothDevice)
        guard permissionsSetUp else { return }
        // Not inside the callback that noticed it: a modal alert there would run the rest of it nested.
        Task { updates.setAutomatic(askAboutUpdates()) }
    }

    func openUpdate(_ page: URL) {
        openPage(page)
    }

    /// Update to 1.2.3…: asks, then downloads and checks the release and swaps it in
    /// (`UpdateInstaller`), then relaunches. A refusal leaves the installed app untouched and the
    /// menu says why. A copy that cannot be replaced without a password opens the release page.
    func installUpdate() {
        guard iconShown, installState != .installing, let offer = updates.offer, confirmUpdate(offer) else { return }
        installState = .installing
        let release = UpdateCheck.Release(version: offer.version, page: offer.page)
        Task {
            let outcome = await install(release, current, installedApp)
            await finishInstall(outcome, offer)
        }
    }

    private func finishInstall(_ outcome: UpdateInstallOutcome, _ offer: UpdateOffer) async {
        switch outcome {
        case .failed(let failure):
            installState = .failed(reason: failure.reason, retry: !failure.opensReleasePage)
            if failure.opensReleasePage { openPage(offer.page) }
        case .installed:
            installState = .idle
            model.flush()
            guard let installedApp, await relaunch(installedApp) else {
                alert(UpdateOffer.relaunchFailed.title, UpdateOffer.relaunchFailed.body)
                return
            }
            terminate()
        }
    }

    func skipUpdate() {
        installState = .idle
        updates.skip()
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
                    Alerts.show("PureMouse couldn't stop.", error.description)
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
