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
enum LoginItem {
    /// Whether this process is the binary of an installed app bundle (not a `swift build` product).
    static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/PureMouse.log")
    private static let menuLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/PureMouse Menu.log")

    private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// The bundled menu bar app, absent from builds that do not include it.
    static var menuApp: URL? {
        let app = Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/PureMouse Menu.app")
        return FileManager.default.isExecutableFile(atPath: menuExecutable(app).path) ? app : nil
    }

    private static func menuExecutable(_ app: URL) -> URL {
        app.appending(path: "Contents/MacOS/PureMouseMenu")
    }

    /// Present after `menu off`: the menu agent stays unregistered until `menu on`.
    private static var hiddenMarker: URL { Companion.directory.appending(path: "menu-hidden") }
    static var menuHidden: Bool { FileManager.default.fileExists(atPath: hiddenMarker.path) }

    /// Installs and starts the agents for this copy of the app (the menu's unless hidden), first
    /// giving the user a config to edit if they have none. Agents already running (an older or
    /// moved copy) are stopped first. Returns a sentence describing the outcome.
    static func register() throws -> String {
        let (label, executable) = try identity()
        seedConfig()
        let restarting = try stop(label)
        try install(label, [
            "Label": label,
            "ProgramArguments": [executable.path, "run"],
            "RunAtLoad": true,
            // Restarted within seconds if it exits, including when it quits to pick up a new
            // permission (Daemon.restartWhenGranted).
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Interactive",
            "StandardErrorPath": logURL.path,
        ])
        var outcome = restarting ? "PureMouse restarted." : "PureMouse is running and will start at login."
        if menuApp != nil {
            if menuHidden {
                try removeAgent(Companion.menuLabel)
                outcome += " The menu bar icon is hidden (`puremouse menu on` shows it)."
            } else {
                try installMenu()
            }
        }
        return outcome
    }

    /// Stops both agents (launchd sends the daemon SIGTERM, so it restores the mouse) and removes
    /// them from login items.
    static func unregister() throws {
        let (label, _) = try identity()
        try removeAgent(label)
        try removeAgent(Companion.menuLabel)
    }

    /// Quit PureMouse: stops both agents but keeps them registered, so both start again at login.
    static func stopAll() throws -> String {
        let (label, _) = try identity()
        let wasRunning = try stop(label)
        try stop(Companion.menuLabel)
        return wasRunning ? "PureMouse stopped; it starts again at login." : "PureMouse was not running."
    }

    /// Shows or hides the menu bar icon by registering or removing the menu agent only. Hiding is
    /// remembered (`hiddenMarker`) so a later `register` keeps it hidden.
    static func showMenu(_ show: Bool) throws -> String {
        _ = try identity()
        let files = FileManager.default
        if show {
            guard menuApp != nil else { throw Failure.noMenuApp }
            do {
                try files.removeItem(at: hiddenMarker)
            } catch CocoaError.fileNoSuchFile {}
            try installMenu()
            return "The menu bar icon is shown."
        }
        try files.createDirectory(at: hiddenMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: hiddenMarker)
        try removeAgent(Companion.menuLabel)
        return "The menu bar icon is hidden; `puremouse menu on` shows it again."
    }

    /// Opens the menu bar app, which then shows Settings (a second launch hands over to the
    /// running one).
    static func openMenu(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [app.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            alert("PureMouse", "cannot open \(app.path): \(error)")
        }
    }

    private static func identity() throws -> (label: String, executable: URL) {
        guard let label = Bundle.main.bundleIdentifier, let executable = Bundle.main.executableURL else {
            throw Failure.notInBundle
        }
        // Quarantined apps opened where they were unzipped run from a randomised read-only copy;
        // an agent pointing there would vanish.
        guard !executable.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        return (label, executable)
    }

    /// Writes and boots the menu agent. When the menu bar app itself asked (its process is our
    /// parent) and its agent is already loaded, the agent is left running: restarting it would
    /// quit the app that is waiting for this command.
    private static func installMenu() throws {
        guard let app = menuApp else { return }
        let label = Companion.menuLabel
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [menuExecutable(app).path],
            "RunAtLoad": true,
            // Relaunched after a crash, not after Quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": menuLogURL.path,
        ]
        if calledFromMenu(app), launchctl("print", target(label)).status == 0 {
            try write(label, agent)
            return
        }
        try stop(label)
        try install(label, agent)
    }

    private static func calledFromMenu(_ app: URL) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(getppid(), &buffer, UInt32(buffer.count)))
        guard length > 0 else { return false }
        let parent = URL(fileURLWithPath: String(decoding: buffer.prefix(length), as: UTF8.self)).resolvingSymlinksInPath()
        return parent == menuExecutable(app).resolvingSymlinksInPath()
    }

    private static func write(_ label: String, _ agent: [String: Any]) throws {
        let plist = plistURL(label)
        let files = FileManager.default
        try files.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
    }

    private static func install(_ label: String, _ agent: [String: Any]) throws {
        try write(label, agent)
        let (status, output) = launchctl("bootstrap", "gui/\(getuid())", plistURL(label).path)
        guard status == 0 else { throw Failure.bootstrap(output) }
    }

    /// Removes the agent's plist, then stops it: the menu bar app may be the caller, and stopping
    /// it last means nothing is left undone if launchd takes this process with it.
    private static func removeAgent(_ label: String) throws {
        do {
            try FileManager.default.removeItem(at: plistURL(label))
        } catch CocoaError.fileNoSuchFile {
            // Never registered, or already removed.
        }
        try stop(label)
    }

    private static func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

    /// Unloads the agent if it is loaded, waiting up to five seconds for the old instance to finish
    /// restoring the mouse. Returns whether it was loaded.
    @discardableResult
    private static func stop(_ label: String) throws -> Bool {
        let job = target(label)
        guard launchctl("print", job).status == 0 else { return false }
        let (_, output) = launchctl("bootout", job)
        for _ in 0..<50 {
            if launchctl("print", job).status != 0 { return true }
            usleep(100_000)
        }
        throw Failure.stillRunning(target: job, output: output)
    }

    private static func launchctl(_ arguments: String...) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "cannot run launchctl") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
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
        case notInBundle, translocated, noMenuApp, bootstrap(String), stillRunning(target: String, output: String)

        var description: String {
            switch self {
            case .notInBundle: "only an installed PureMouse.app can register itself to start at login"
            case .translocated: "move PureMouse to the Applications folder, then open it again"
            case .noMenuApp: "this build of PureMouse has no menu bar app"
            case .stillRunning(let target, let output):
                "the running PureMouse did not stop (\(output)); try `launchctl bootout \(target)`"
            case .bootstrap(let output):
                "launchd would not start PureMouse (\(output)); check it is allowed under System Settings › General › Login Items"
            }
        }
    }
}
