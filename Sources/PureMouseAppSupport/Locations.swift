import Foundation
import PureMouseKit

/// Where things live. Development overrides (never set in an installed app):
/// `PUREMOUSE_CONFIG` (the config file), `PUREMOUSE_DAEMON` (the daemon binary) and
/// `PUREMOUSE_COMPANION_DIR` (the status/control channel; see `Companion.directory`).
enum Paths {
    private static let environment = ProcessInfo.processInfo.environment
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let config: URL = {
        if let path = environment["PUREMOUSE_CONFIG"] { return URL(fileURLWithPath: path) }
        return home.appending(path: ".config/puremouse/config.json")
    }()

    static let log = home.appending(path: "Library/Logs/PureMouse.log")

    /// The daemon binary of the app this one is nested in:
    /// `PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app` → `PureMouse.app/Contents/MacOS/puremouse`.
    static let daemon: URL? = {
        if let path = environment["PUREMOUSE_DAEMON"] { return URL(fileURLWithPath: path) }
        let url = Bundle.main.bundleURL.appending(path: "../../../MacOS/puremouse").standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    static func launchAgent(_ label: String) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Start at login: the daemon's agent exists.
    static var startsAtLogin: Bool { FileManager.default.fileExists(atPath: launchAgent(Companion.daemonLabel).path) }

    /// Show in menu bar: the daemon's `menu off` leaves a `menu-hidden` marker beside the status
    /// file, and `menu on` removes it (docs/companion.md, "Daemon decisions"). A development build
    /// always shows its icon.
    static var showsInMenuBar: Bool {
        environment["PUREMOUSE_DAEMON"] != nil || daemon == nil
            || !FileManager.default.fileExists(atPath: Companion.directory.appending(path: "menu-hidden").path)
    }

    /// launchd started this process (at login, or `puremouse register`/`menu on`), rather than the
    /// Finder or a second `open`.
    static var launchedByLaunchd: Bool {
        CommandLine.arguments.contains("--login") || environment["XPC_SERVICE_NAME"] == Companion.menuLabel
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
