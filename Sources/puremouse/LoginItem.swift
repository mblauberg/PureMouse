import CoreFoundation
import Foundation

/// Starting PureMouse at login: a launchd agent, `~/Library/LaunchAgents/<bundle id>.plist`, that
/// runs this app's binary. Opening the app writes and loads it, so installing is copying the app
/// and opening it once. macOS lists it under System Settings › General › Login Items as a
/// background item, where it can be switched off.
///
/// Not `SMAppService`: without a Developer ID team, launchd pins its agents to the exact build that
/// registered them, and after an update refuses to start the new binary (EX_CONFIG).
enum LoginItem {
    /// Whether this process is the binary of an installed app bundle (not a `swift build` product).
    static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/PureMouse.log")

    private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Installs and starts the agent for this copy of the app, first giving the user a config to
    /// edit if they have none. An agent already running (an older or moved copy) is stopped first.
    /// Returns a sentence describing the outcome.
    static func register() throws -> String {
        guard let label = Bundle.main.bundleIdentifier, let executable = Bundle.main.executableURL else {
            throw Failure.notInBundle
        }
        // Quarantined apps opened where they were unzipped run from a randomised read-only copy;
        // an agent pointing there would vanish.
        guard !executable.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        seedConfig()
        let restarting = try stop(label)
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "run"],
            "RunAtLoad": true,
            // Restarted within seconds if it exits, including when it quits to pick up a new
            // permission (Daemon.restartWhenGranted).
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Interactive",
            "StandardErrorPath": logURL.path,
        ]
        let plist = plistURL(label)
        let files = FileManager.default
        try files.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        let (status, output) = launchctl("bootstrap", "gui/\(getuid())", plist.path)
        guard status == 0 else { throw Failure.bootstrap(output) }
        return restarting ? "PureMouse restarted." : "PureMouse is running and will start at login."
    }

    /// Stops the agent (launchd sends it SIGTERM, so it restores the mouse) and removes it from
    /// login items.
    static func unregister() throws {
        guard let label = Bundle.main.bundleIdentifier else { throw Failure.notInBundle }
        try stop(label)
        try? FileManager.default.removeItem(at: plistURL(label))
    }

    /// Unloads the agent if it is loaded, waiting up to five seconds for the old instance to finish
    /// restoring the mouse. Returns whether it was loaded.
    @discardableResult
    private static func stop(_ label: String) throws -> Bool {
        let target = "gui/\(getuid())/\(label)"
        guard launchctl("print", target).status == 0 else { return false }
        let (_, output) = launchctl("bootout", target)
        for _ in 0..<50 {
            if launchctl("print", target).status != 0 { return true }
            usleep(100_000)
        }
        throw Failure.stillRunning(output)
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
        case notInBundle, translocated, bootstrap(String), stillRunning(String)

        var description: String {
            switch self {
            case .notInBundle: "only an installed PureMouse.app can register itself to start at login"
            case .translocated: "move PureMouse to the Applications folder, then open it again"
            case .stillRunning(let output):
                "the running PureMouse did not stop (\(output)); try `launchctl bootout gui/$UID/io.github.mblauberg.puremouse`"
            case .bootstrap(let output):
                "launchd would not start PureMouse (\(output)); check it is allowed under System Settings › General › Login Items"
            }
        }
    }
}
