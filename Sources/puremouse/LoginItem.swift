import Foundation
import PureMouseKit

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
        /// Copies the bundled example config unless one is there.
        var seedConfig: () -> Void
        /// The bundled Settings helper, absent from builds that do not include it.
        var settingsApp: URL?
        /// Asks for Settings to open (`SettingsRequest`), for the helper to read when it starts.
        var requestSettings: () -> Void
        /// Opens the app, trying up to the given number of times; whether it opened.
        var open: (URL, Int) -> Bool

        static var live: Host {
            Host(executable: LoginItem.liveExecutable, menuApp: LoginItem.menuApp,
                 hiddenMarker: Companion.directory.appending(path: Companion.menuHiddenName),
                 lockFile: FileLock.url(for: Companion.directory.appending(path: "lifecycle")), lockTimeout: 30,
                 calledFromMenu: LoginItem.parentIsMenu, seedConfig: LoginItem.seedConfig,
                 settingsApp: LoginItem.settingsApp, requestSettings: { SettingsRequest.write("") },
                 open: LoginItem.open)
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
    /// The menu bar app, unless this build has none or `menu off` hid it.
    private var shownMenuApp: URL? { menuHidden ? nil : host.menuApp }

    /// Runs `body` with this build's executable, once nothing else is changing what is registered
    /// or running. A build that cannot register itself fails before anything is locked or touched.
    private func exclusive<T>(_ body: (URL) throws -> T) throws -> T {
        let executable = try host.executable()
        return try FileLock.withLock(host.lockFile, timeout: host.lockTimeout) { try body(executable) }
    }

    // MARK: Commands

    /// Installs and starts the agents for this copy of the app (the menu's unless hidden), first
    /// giving the user a config to edit if they have none. Agents already running (an older or
    /// moved copy) are stopped first. Returns a sentence describing the outcome.
    func register() throws -> String {
        try exclusive { executable in
            host.seedConfig()
            let restarting = try service.stop(.daemon)
            try service.register(.daemon, at: executable)
            try service.start(.daemon, at: executable)
            var outcome = restarting ? "PureMouse restarted." : "PureMouse is running and will start at login."
            if let app = host.menuApp {
                if menuHidden {
                    try remove(.menu)
                    outcome += " The menu bar icon is hidden (`puremouse menu on` shows it)."
                } else {
                    try installMenu(app)
                }
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
            guard wasRunning else { return "PureMouse was not running." }
            return service.status(.daemon) == .enabled ? "PureMouse stopped; it starts again at login." : "PureMouse stopped."
        }
    }

    /// Makes both agents (the menu's unless hidden) start at login, without starting or
    /// restarting anything now.
    func loginOn() throws -> String {
        try exclusive { executable in
            host.seedConfig()
            try service.register(.daemon, at: executable)
            if let app = shownMenuApp {
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
                ? "PureMouse will not start at login; it keeps running until you quit it (`puremouse stop`)."
                : "PureMouse will not start at login."
        }
    }

    /// Starts the agents that are not running (the menu's unless hidden), without changing whether
    /// they start at login. A job that is loaded but has no process (the menu after Quit) is
    /// started too; running ones are left alone.
    func start() throws -> String {
        try exclusive { executable in
            var started = try service.start(.daemon, at: executable)
            if let app = shownMenuApp {
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

    /// Shows or hides the menu bar icon by registering or removing the menu agent only. Hiding is
    /// remembered (`hiddenMarker`) so a later `register` keeps it hidden.
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
            try remove(.menu)
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

    /// Opens the Settings helper, which reads the request left in `Companion.showSettingsURL`
    /// (`SettingsRequest`, under its lock) when it starts. It is opened itself, not through the menu
    /// bar app, which `register` starts unless its icon is hidden and which has no part in
    /// Settings. `open` is tried twice, since it can fail while LaunchServices is busy. False if the
    /// build has no helper or it would not open.
    func openSettings() -> Bool {
        guard let settings = host.settingsApp else { return false }
        host.requestSettings()
        return host.open(settings, 2)
    }

    /// The bundled Settings helper, absent from builds that do not include it.
    static var settingsApp: URL? {
        let app = Bundle.main.bundleURL.appending(path: "Contents/Helpers/PureMouse Settings.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
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

    /// Copies the bundled example to `Config.defaultURL` unless a config is already there.
    private static func seedConfig() {
        let target = Config.defaultURL
        guard !FileManager.default.fileExists(atPath: target.path),
              let example = Bundle.main.url(forResource: "config.example", withExtension: "json") else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: example, to: target)
    }

    /// Shows a system alert and waits for it to be dismissed. CoreFoundation's user notifications
    /// need no AppKit, which a background-only app does not otherwise load.
    static func alert(_ header: String, _ message: String) {
        var response: CFOptionFlags = 0
        CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel, nil, nil, nil,
                                       header as CFString, message as CFString, nil, nil, nil, &response)
    }

    enum Failure: Error, CustomStringConvertible {
        case notInBundle, translocated, noMenuApp

        var description: String {
            switch self {
            case .notInBundle: "only an installed PureMouse.app can register itself to start at login"
            case .translocated: "move PureMouse to the Applications folder, then open it again"
            case .noMenuApp: "this build of PureMouse has no menu bar app"
            }
        }
    }
}
