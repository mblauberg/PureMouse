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
    var relaunch: @MainActor (URL, InstallSource) async -> Bool = { UpdateSetup.relaunchLive($0, from: $1) }
    var openPage: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    var alert: @MainActor (String, String) -> Void = Alerts.show
    /// Answers `applicationShouldTerminate` once an install that was ending has finished.
    var replyToTerminate: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    @MainActor static var live: UpdateSetup {
        UpdateSetup(preferences: UpdatePreferences(.standard),
                    scheduler: BackgroundActivity(identifier: Companion.menuLabel + ".update-check"),
                    ask: Alerts.askAboutUpdates, announce: { Notifier.post($0) })
    }

    /// Quits Settings, then starts the installed app's new copy (`register`, which opens no
    /// window). The quit is the reversible one: if the app does not open, this process stays and
    /// Settings opens again from its menu. Settings comes back only if it was showing, where it
    /// was, or on About for an update asked for from About, and is asked for before the app is
    /// opened: `register` replaces this process, which may not get to ask after.
    @MainActor static func relaunchLive(_ app: URL, from source: InstallSource, launcher: SettingsLauncher = .shared,
                                        open: @MainActor (URL) -> Bool = UpdateRelaunch.open) -> Bool {
        let settingsWasOpen = launcher.quitRunning()
        switch source {
        case .about: launcher.open(ShowRequest(pane: .tab(.about)))
        case .menu: if settingsWasOpen { launcher.open(ShowRequest()) }
        }
        return open(app)
    }
}

/// Where an update was asked for, which decides what Settings does across the relaunch.
enum InstallSource: Equatable {
    case menu, about
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
    private let relaunch: @MainActor (URL, InstallSource) async -> Bool
    private let openPage: @MainActor (URL) -> Void
    private let terminate: @MainActor () -> Void
    private let alert: @MainActor (String, String) -> Void
    private let replyToTerminate: @MainActor (Bool) -> Void
    private let preferences: UpdatePreferences
    /// Where an update chosen from the menu or from About stands; the menu shows it, and About is told
    /// through the preferences (`UpdatePreferences.installStatus`).
    private(set) var installState = UpdateInstallState.idle {
        didSet { publishInstallStatus() }
    }
    /// The install under way, kept so that Quit and Hide wait for its cleanup.
    private var installTask: Task<Void, Never>?
    private var installingTitle: String?
    /// The installer is reserved while the confirmation is up: its alert runs a nested run loop in
    /// which another request (the menu row, About, another process writing the preference) can arrive.
    private var confirming = false
    /// Quit, Hide or a termination has been asked for: an install that finishes now is not followed
    /// by a relaunch.
    private var leaving = false
    private var requestWatch: UpdatePreferences.Watch?

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
        replyToTerminate = setup.replyToTerminate
        preferences = setup.preferences
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

    /// Not while an update is being installed: it is cancelled, and the app ends once the image is
    /// detached and the download deleted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard installTask != nil else { return .terminateNow }
        afterInstallEnds { [replyToTerminate] in replyToTerminate(true) }
        return .terminateLater
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
        // About asks for installs through the preferences, which a hidden-icon run hears as well.
        preferences.installStatus = nil
        requestWatch = UpdatePreferences.Watch(preferences.defaults, .installRequest) { [weak self] in self?.installRequested() }
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

    /// Update to 1.2.3…: the menu row.
    func installUpdate() {
        guard iconShown, let offer = updates.offer else { return }
        startInstall(offer, from: .menu)
    }

    /// Settings' About pane asked for this release (`UpdatePreferences.installRequest`). The request
    /// is cleared at once, and the same flow as the menu row follows: ask, install, relaunch.
    func installRequested() {
        guard let release = preferences.installRequest else { return }
        preferences.installRequest = nil
        guard UpdateInstaller.names(release), let running = UpdateCheck.Version(current), release.version > running else {
            return
        }
        startInstall(UpdateOffer(version: release.version, page: release.page), from: .about)
    }

    /// Asks, then downloads and checks the release and swaps it in (`UpdateInstaller`), then
    /// relaunches. A refusal leaves the installed app untouched and says why. A copy that cannot be
    /// replaced without a password opens the release page. One install at a time, the installer
    /// being reserved from the confirmation on; none once quitting has begun.
    func startInstall(_ offer: UpdateOffer, from source: InstallSource) {
        guard installTask == nil, !confirming, !leaving else { return }
        confirming = true
        let confirmed = confirmUpdate(offer)
        confirming = false
        // Quit or Hide may have been chosen while the alert was up; nothing starts after that.
        guard confirmed, !leaving, installTask == nil else { return }
        installingTitle = offer.installingTitle
        installState = .installing
        let release = UpdateCheck.Release(version: offer.version, page: offer.page)
        installTask = Task {
            let outcome = await install(release, current, installedApp)
            await finishInstall(outcome, offer, from: source)
            installTask = nil
        }
    }

    private func finishInstall(_ outcome: UpdateInstallOutcome, _ offer: UpdateOffer, from source: InstallSource) async {
        switch outcome {
        case .failed(.cancelled):
            installState = .idle
        case .failed(let failure):
            installState = .failed(reason: failure.reason, retry: !failure.opensReleasePage)
            if failure.opensReleasePage { openPage(offer.page) }
        case .installed:
            // The app on disk is the new one, and the menu stops offering it.
            installState = .installed
            model.flush()
            guard !leaving else { return }
            guard let installedApp, await relaunch(installedApp, source) else {
                alert(UpdateOffer.relaunchFailed.title, UpdateOffer.relaunchFailed.body)
                return
            }
            terminate()
        }
    }

    private func publishInstallStatus() {
        switch installState {
        case .installing: preferences.installStatus = installingTitle
        case .failed(let reason, _): preferences.installStatus = reason
        case .idle, .installed: preferences.installStatus = nil
        }
    }

    /// Runs `work` once no install is under way: one that is gets cancelled, and `work` follows its
    /// cleanup (the image detached, the download deleted), since what comes next ends this process.
    func afterInstallEnds(_ work: @escaping @MainActor () -> Void) {
        leaving = true
        guard let task = installTask else { return work() }
        task.cancel()
        Task {
            await task.value
            work()
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
        afterInstallEnds { [self] in quitNow() }
    }

    private func quitNow() {
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
        afterInstallEnds { [self] in
            model.flush()
            model.perform(.menuOff) { [self] in
                statusMenu?.remove()
                statusMenu = nil
                NSApp.terminate(nil)
            }
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
