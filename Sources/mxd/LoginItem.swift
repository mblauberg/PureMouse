import CoreFoundation
import Foundation
import ServiceManagement

/// Starting mxd at login. The app carries its own launchd agent
/// (`Contents/Library/LaunchAgents/<bundle id>.plist`) and registers it with `SMAppService`, so
/// installing is copying the app and opening it once, and the agent shows under System Settings ›
/// General › Login Items, where it can be switched off.
enum LoginItem {
    /// Whether this process is the binary of an installed app bundle (not a `swift build` product).
    static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    private static var service: SMAppService? {
        Bundle.main.bundleIdentifier.map { .agent(plistName: "\($0).plist") }
    }

    /// Registers and starts the agent, first giving the user a config to edit if they have none.
    /// If it is already registered, restarts it, so opening a replaced app runs the new binary.
    /// Returns a sentence describing the outcome.
    static func register() throws -> String {
        guard let service, let label = Bundle.main.bundleIdentifier else { throw Failure.notInBundle }
        // Quarantined apps opened where they were unzipped run from a randomised read-only copy;
        // an agent registered there would vanish.
        guard !Bundle.main.bundlePath.contains("/AppTranslocation/") else { throw Failure.translocated }
        seedConfig()
        if service.status == .enabled {
            // launchd sends SIGTERM, so the old instance restores the mouse before it goes.
            try launchctl("kickstart", "-k", "gui/\(getuid())/\(label)")
            return "mxd restarted."
        }
        do {
            try service.register()
        } catch where service.status == .requiresApproval {
            // Switched off under Login Items: register() refuses until the user allows it there.
        }
        switch service.status {
        case .enabled:
            return "mxd is running and will start at login."
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return "Allow mxd under System Settings › General › Login Items to start it."
        case .notFound:
            throw Failure.agentMissing
        default:
            throw Failure.notRegistered
        }
    }

    /// Stops the agent (launchd sends it SIGTERM, so it restores the mouse) and removes it from
    /// login items.
    static func unregister() throws {
        guard let service else { throw Failure.notInBundle }
        if service.status != .notRegistered { try service.unregister() }
    }

    private static func launchctl(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.restart(process.terminationStatus) }
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
        case notInBundle, translocated, agentMissing, notRegistered, restart(Int32)

        var description: String {
            switch self {
            case .notInBundle: "only an installed mxd.app can register itself to start at login"
            case .translocated: "move mxd to the Applications folder, then open it again"
            case .agentMissing: "the app's login agent is missing; reinstall mxd"
            case .notRegistered: "macOS did not register the login agent; see System Settings › General › Login Items"
            case .restart(let status): "launchctl could not restart mxd (exit status \(status))"
            }
        }
    }
}
