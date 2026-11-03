import Foundation
import PureMouseKit
import notify

/// Starting PureMouse at login: launchd agents in `~/Library/LaunchAgents/<label>.plist`, one
/// for the daemon (this app's binary) and one for the menu bar app inside it, when the build has
/// one. Opening the app writes and loads them, so installing is copying the app and opening it
/// once. macOS lists them under System Settings › General › Login Items as background items,
/// where they can be switched off. The daemon's CLI owns every launchd change; the menu bar app
/// runs these commands through it (docs/companion.md, "Login and lifecycle").
///
/// Not `SMAppService`: without a Developer ID team, launchd pins its agents to the exact build that
/// registered them, and after an update refuses to start the new binary (EX_CONFIG).
///
/// The menu bar app runs these commands as a child process, and launchd kills a job's process
/// group when booting it out, so `main` moves the CLI into its own session first, and each
/// command boots the menu agent out last.
///
/// Every command that changes what is registered or running holds one lock file in the companion
/// directory, so two of them (the menu and a terminal, or a double click) run one after the other;
/// `login-status` only reads and takes none.
///
/// This type is the policy (daemon before menu, the menu last, `menu off` remembered, the caller's
/// own agent left running); the mechanism is a `LoginService`, so the policy is tested against a
/// fake. "Starts at login" and "is running now" are separate: `login on|off` change the first,
/// `start` and `stop` the second (docs/companion.md, "Login and lifecycle").
struct LoginItem {
    /// What the policy asks of the machine it runs on, replaceable in tests.
    struct Host {
        /// This build's executable, or why it cannot be registered.
        var executable: () throws -> URL
        /// The bundled menu bar app, absent from builds that do not include it.
        var menuApp: URL?
        /// Present after `menu off`: the menu agent stays unregistered until `menu on`.
        var hiddenMarker: URL
        /// Held by every command that changes what is registered or running, so two of them (the
        /// menu and a terminal, or a double click) run one after the other.
        var lockFile: URL
        /// How long a command waits for `lockFile` before giving up.
        var lockTimeout: TimeInterval
        /// Whether this process was started by the menu bar app whose executable is given.
        var calledFromMenu: (URL) -> Bool
        /// The bundled Settings helper, absent from builds that do not include it.
        var settingsApp: URL?
        /// Asks for Settings to open: writes the request (`SettingsRequest`) and rings the doorbell,
        /// so a helper that starts later reads the file and one already running is told to.
        var requestSettings: () -> Void
        /// Whether the request is still in the file: the helper removes it when it reads it.
        var requestPending: () -> Bool
        /// Whether Quit PureMouse has stamped a quit since the last request was written (a request
        /// clears the stamp), read as the helper reads it (`SettingsRequest.quitUnderWay`).
        var quitStamped: () -> Bool
        /// Sleeps for the interval between looks at `requestPending`.
        var pause: (TimeInterval) -> Void
        /// Opens the app, trying up to the given number of times; whether it opened.
        var open: (URL, Int) -> Bool

        static var live: Host {
            Host(executable: LoginItem.liveExecutable, menuApp: LoginItem.menuApp,
                 hiddenMarker: Companion.directory.appending(path: Companion.menuHiddenName),
                 lockFile: FileLock.url(for: Companion.directory.appending(path: "lifecycle")), lockTimeout: 30,
                 calledFromMenu: LoginItem.parentIsMenu,
                 settingsApp: LoginItem.settingsApp, requestSettings: LoginItem.requestSettings,
                 requestPending: { FileManager.default.fileExists(atPath: Companion.showSettingsURL.path) },
                 quitStamped: { SettingsRequest.quitUnderWay() },
                 pause: Thread.sleep(forTimeInterval:), open: LoginItem.open)
        }
    }

    var service: LoginService = LaunchdAgentService()
    var host: Host = .live

    /// Whether this process is the binary of an installed app bundle (not a `swift build` product).
    static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// The bundled menu bar app, absent from builds that do not include it.
    static var menuApp: URL? {
        let app = Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/PureMouse Menu.app")
        return FileManager.default.isExecutableFile(atPath: Job.menuExecutable(in: app).path) ? app : nil
    }

    private var menuHidden: Bool { FileManager.default.fileExists(atPath: host.hiddenMarker.path) }
    /// Runs `body` with this build's executable, once nothing else is changing what is registered
    /// or running. A build that cannot register itself fails before anything is locked or touched.
    private func exclusive<T>(_ body: (URL) throws -> T) throws -> T {
        let executable = try host.executable()
        return try FileLock.withLock(host.lockFile, timeout: host.lockTimeout) { try body(executable) }
    }

    // MARK: Commands

    /// Installs and starts the agents for this copy of the app. It writes
    /// no config: a missing one means the default set. Agents already running (an older or
    /// moved copy) are stopped first. Returns a sentence describing the outcome.
    func register() throws -> String {
        try exclusive { executable in
            let restarting = try service.stop(.daemon)
            try service.register(.daemon, at: executable)
            try service.start(.daemon, at: executable)
            var outcome = restarting ? "PureMouse restarted." : "PureMouse is running and will start at login."
            if let app = host.menuApp {
                // Hidden or not, the menu process runs: hidden, it has no status item but goes on
                // with low-battery notifications and the update check (`AppController`).
                try installMenu(app)
                if menuHidden { outcome += " The menu bar icon is hidden (`puremouse menu on` shows it)." }
            }
            return outcome
        }
    }

    /// Stops both agents (launchd sends the daemon SIGTERM, so it restores the mouse) and removes
    /// them from login items.
    func unregister() throws {
        try exclusive { _ in
            try remove(.daemon)
            try remove(.menu)
        }
    }

    /// Quit PureMouse: stops both agents but keeps them registered, so both start again at login.
    func stopAll() throws -> String {
        try exclusive { _ in
            let wasRunning = try service.stop(.daemon)
            try service.stop(.menu)
            guard wasRunning else { return "PureMouse wasn't running." }
            return service.status(.daemon) == .enabled ? "PureMouse stopped; it starts again at login." : "PureMouse stopped."
        }
    }

    /// Makes both agents start at login, without starting or restarting anything now.
    func loginOn() throws -> String {
        try exclusive { executable in
            try service.register(.daemon, at: executable)
            if let app = host.menuApp {
                try service.register(.menu, at: app)
            }
            return "PureMouse will start at login."
        }
    }

    /// Stops both agents starting at login, without stopping what is running: a running agent
    /// stays loaded until logout or `stop`.
    func loginOff() throws -> String {
        try exclusive { _ in
            let running = service.state(.daemon) == .running
            try service.unregister(.daemon)
            try service.unregister(.menu)
            return running
                ? "PureMouse won't start at login; it keeps running until you quit it (`puremouse stop`)."
                : "PureMouse won't start at login."
        }
    }

    /// Starts the agents that are not running, without changing whether
    /// they start at login. A job that is loaded but has no process (the menu after Quit) is
    /// started too; running ones are left alone.
    func start() throws -> String {
        try exclusive { executable in
            var started = try service.start(.daemon, at: executable)
            if let app = host.menuApp {
                started = try service.start(.menu, at: app) || started
            }
            return started ? "PureMouse started." : "PureMouse is already running."
        }
    }

    /// What `puremouse login-status` prints.
    func loginStatus() -> LoginStatus {
        LoginStatus(service: service.name, daemon: service.status(.daemon),
                    menu: host.menuApp == nil ? .notFound : service.status(.menu), hidden: menuHidden)
    }

    /// Shows or hides the menu bar icon by restarting the menu agent only, which reads
    /// `hiddenMarker` as it starts: hidden, the process runs without a status item. Hiding is
    /// remembered so a later `register` keeps it hidden. Called from the menu bar app itself, the
    /// agent is registered but not restarted (that would end the caller): on hiding it removes its
    /// own status item and carries on (`AppController.hideMenuBarIcon`).
    func showMenu(_ show: Bool) throws -> String {
        try exclusive { _ in
            let files = FileManager.default
            if show {
                guard let app = host.menuApp else { throw Failure.noMenuApp }
                do {
                    try files.removeItem(at: host.hiddenMarker)
                } catch CocoaError.fileNoSuchFile {}
                try installMenu(app)
                return "The menu bar icon is shown."
            }
            try files.createDirectory(at: host.hiddenMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: host.hiddenMarker)
            if let app = host.menuApp { try installMenu(app) }
            return "The menu bar icon is hidden; `puremouse menu on` shows it again."
        }
    }

    /// What opening the app from the Finder did.
    struct FinderLaunch: Equatable {
        /// What `register` reported.
        var outcome: String
        /// Whether Settings opened; if not, the caller tells the user the outcome itself.
        var settingsOpened: Bool
    }

    /// Opening the app from the Finder: `register`, then Settings. Registration has happened by the
    /// time Settings is attempted, so a missing or unopenable helper leaves it done.
    func finderLaunch() throws -> FinderLaunch {
        let outcome = try register()
        return FinderLaunch(outcome: outcome, settingsOpened: openSettings())
    }

    /// How long `openSettings` waits for the helper to read the request, and how often it looks.
    static let settingsWait: (total: TimeInterval, interval: TimeInterval) = (2, 0.2)

    /// Opens the Settings helper with a request for it to show itself, and checks that it was
    /// taken. It is opened itself, not through the menu bar app, which `register` starts unless its
    /// icon is hidden and which has no part in Settings. `open` exiting 0 is not enough: when the
    /// helper has just quit, LaunchServices can answer with the instance that is exiting, which
    /// never reads the request. The helper removes the request when it reads it (`ShowRequest`),
    /// so a request still there after `settingsWait` means no helper took it, and `open` is
    /// tried once more, with the request written again so it is fresh for the new instance, unless
    /// Quit PureMouse stamped a quit meanwhile: writing again would clear the stamp and bring
    /// Settings back after a quit, so nothing more is done (true, so no alert either). False if the
    /// build has no helper or `open` fails.
    func openSettings() -> Bool {
        guard let settings = host.settingsApp else { return false }
        host.requestSettings()
        guard host.open(settings, 2) else { return false }
        if requestTaken() || host.quitStamped() { return true }
        host.requestSettings()
        return host.open(settings, 2)
    }

    /// Whether the helper reads the request within `settingsWait`.
    private func requestTaken() -> Bool {
        var waited: TimeInterval = 0
        while host.requestPending() {
            guard waited < Self.settingsWait.total else { return false }
            host.pause(Self.settingsWait.interval)
            waited += Self.settingsWait.interval
        }
        return true
    }

    /// The bundled Settings helper, absent from builds that do not include it.
    static var settingsApp: URL? {
        let app = Bundle.main.bundleURL.appending(path: "Contents/Helpers/PureMouse Settings.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Writes the Settings request and rings the doorbell a running helper listens on.
    private static func requestSettings() {
        SettingsRequest.write("")
        notify_post(Companion.showSettingsNotification)
    }

    /// `open` with the app, `attempts` times a second apart until it succeeds.
    private static func open(_ app: URL, _ attempts: Int) -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [app.path]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }

    /// Registers and starts the menu agent. When the menu bar app itself asked (its process is our
    /// parent) and its agent is already loaded, the agent is left running: restarting it would
    /// quit the app that is waiting for this command.
    private func installMenu(_ app: URL) throws {
        if host.calledFromMenu(app), service.state(.menu) != .notLoaded {
            try service.register(.menu, at: app)
            return
        }
        try service.stop(.menu)
        try service.register(.menu, at: app)
        try service.start(.menu, at: app)
    }

    /// Removes the job from login, then stops it: the menu bar app may be the caller, and stopping
    /// it last means nothing is left undone if launchd takes this process with it.
    private func remove(_ job: Job) throws {
        try service.unregister(job)
        try service.stop(job)
    }

    private static func liveExecutable() throws -> URL {
        guard Bundle.main.bundleIdentifier != nil, let executable = Bundle.main.executableURL else {
            throw Failure.notInBundle
        }
        // Quarantined apps opened where they were unzipped run from a randomised read-only copy;
        // an agent pointing there would vanish.
        guard !executable.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        return executable
    }

    private static func parentIsMenu(_ app: URL) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(getppid(), &buffer, UInt32(buffer.count)))
        guard length > 0 else { return false }
        let parent = URL(fileURLWithPath: String(decoding: buffer.prefix(length), as: UTF8.self)).resolvingSymlinksInPath()
        return parent == Job.menuExecutable(in: app).resolvingSymlinksInPath()
    }

    /// Shows a system alert and waits for it to be dismissed. CoreFoundation's user notifications
    /// need no AppKit, which a background-only app does not otherwise load.
    static func alert(_ header: String, _ message: String) {
        var response: CFOptionFlags = 0
        CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel, nil, nil, nil,
                                       header as CFString, message as CFString, nil, nil, nil, &response)
    }

    /// What opening from the Finder says when the agents are running but Settings did not open.
    /// "Running" holds whether `register` started PureMouse or restarted it.
    static let runningAlert = (
        title: "PureMouse is running.",
        body: """
            It will open at login. macOS will ask you to allow Accessibility and Input Monitoring. \
            Choose Allow for each, or turn them on in System Settings › Privacy & Security.
            """)

    /// What a Finder launch that threw says: a `Failure` has its own words; anything else (launchd's
    /// output, say) goes to the log and the user gets the next step.
    static func startFailureAlert(_ error: Error) -> (title: String, body: String) {
        if let failure = error as? Failure { return failure.alert }
        return ("PureMouse couldn't start.", "Try again. If it keeps happening, restart your Mac.")
    }

    enum Failure: Error, CustomStringConvertible {
        case notInBundle, translocated, noMenuApp

        /// What a failed Finder launch tells the user: what failed, then what to do.
        var alert: (title: String, body: String) {
            switch self {
            case .notInBundle:
                ("This copy of PureMouse can't open at login.", "Install it from the disk image, then open it again.")
            case .translocated:
                ("PureMouse needs to be in your Applications folder.", "Move it there, then open it again.")
            case .noMenuApp:
                ("This copy of PureMouse has no menu bar icon.", "Install it from the disk image, then open it again.")
            }
        }

        /// The same on one line, for the CLI.
        var description: String { "\(alert.title) \(alert.body)" }
    }
}
