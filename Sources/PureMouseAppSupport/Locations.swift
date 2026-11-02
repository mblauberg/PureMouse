import Foundation
import PureMouseKit

/// Where things live. `live` reads this process's environment; tests build one over a temporary
/// directory. Development overrides (never set in an installed app): `PUREMOUSE_CONFIG` (the
/// config file), `PUREMOUSE_DAEMON` (the daemon binary) and `PUREMOUSE_COMPANION_DIR` (the
/// status/control channel; see `Companion.directory`).
public struct Locations: Sendable {
    /// The config file, as given (it may be a symlink; `ConfigFile` resolves it).
    public var config: URL
    public var log: URL
    /// The daemon binary, nil when this copy is not inside PureMouse.app.
    public var daemon: URL?
    /// The status/control channel's directory.
    public var companion: URL
    /// `PUREMOUSE_DAEMON` is set: a development run against a stub daemon.
    var daemonOverridden: Bool

    public init(config: URL, log: URL, daemon: URL?, companion: URL, daemonOverridden: Bool = false) {
        self.config = config
        self.log = log
        self.daemon = daemon
        self.companion = companion
        self.daemonOverridden = daemonOverridden
    }

    /// Resolves every location as an installed app (or a development run with overrides) would.
    /// `bundle` is this app's bundle: the daemon is looked for in the app it is nested in, the
    /// nearest enclosing `Contents` (`PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app`
    /// and `PureMouse.app/Contents/Helpers/PureMouse Settings.app` → `PureMouse.app/Contents/MacOS/puremouse`).
    init(environment: [String: String], home: URL, bundle: URL,
                isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        config = environment["PUREMOUSE_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config/puremouse/config.json")
        log = home.appending(path: "Library/Logs/PureMouse.log")
        if let path = environment["PUREMOUSE_DAEMON"] {
            daemon = URL(fileURLWithPath: path)
        } else {
            let parents = bundle.standardizedFileURL.pathComponents.dropLast()
            daemon = parents.lastIndex(of: "Contents").map { index in
                URL(fileURLWithPath: NSString.path(withComponents: Array(parents[...index]))).appending(path: "MacOS/puremouse")
            }.flatMap { isExecutable($0) ? $0 : nil }
        }
        companion = Companion.overrideDirectory(in: environment).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: "Library/Application Support/PureMouse")
        daemonOverridden = environment["PUREMOUSE_DAEMON"] != nil
    }

    public static let live = Locations(environment: ProcessInfo.processInfo.environment,
                                       home: FileManager.default.homeDirectoryForCurrentUser,
                                       bundle: Bundle.main.bundleURL)

    /// Written by the daemon: `Status`.
    public var status: URL { companion.appending(path: "status.json") }
    /// Written by the menu bar app and the Settings helper: `Control`.
    public var control: URL { companion.appending(path: "control.json") }
    /// The low-battery bands already announced (`BatteryAlertStore`).
    public var batteryAlerts: URL { companion.appending(path: "battery-alerts.json") }
    /// Left by the daemon's `menu off`, removed by `menu on`.
    var menuHidden: URL { companion.appending(path: Companion.menuHiddenName) }

    /// Show in menu bar: the daemon's `menu off` leaves a `menu-hidden` marker beside the status
    /// file, and `menu on` removes it (docs/companion.md, "Daemon decisions"). A development build
    /// always shows its icon.
    public var showsInMenuBar: Bool {
        daemonOverridden || daemon == nil || !FileManager.default.fileExists(atPath: menuHidden.path)
    }

    /// launchd started this process (at login, or `puremouse register`/`menu on`), rather than the
    /// Finder or a second `open`.
    public static var launchedByLaunchd: Bool {
        CommandLine.arguments.contains("--login")
            || ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Companion.menuLabel
    }

    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
