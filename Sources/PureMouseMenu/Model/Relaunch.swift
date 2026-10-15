import Foundation
import PureMouseKit

/// After Settings closes, AppKit and SwiftUI keep about 30 MB that `malloc_zone_pressure_relief`
/// does not return, so the menu app starts over as a fresh copy, which shows only its icon.
/// `exec` in place is no good: LaunchServices keeps the old image's registration for the pid and
/// the new one never gets its status item.
@MainActor
enum Relaunch {
    /// EX_TEMPFAIL: "try again". Not a crash, and not a successful exit, so launchd restarts it.
    static let exitCode: Int32 = 75

    /// launchd delays a respawn until 10 s after the last one (ThrottleInterval), and the icon
    /// would be gone meanwhile, so a process launched at `uptime` waits that out first.
    static func delay(launchedAt uptime: TimeInterval) -> TimeInterval {
        max(0.5, 11 - (ProcessInfo.processInfo.systemUptime - uptime))
    }

    /// Ends this process so that the menu agent starts afresh; returns only if it cannot.
    /// The agent's own copy exits for launchd (`KeepAlive` unless successful) to restart it. A copy
    /// the Finder started (the icon was hidden, then shown again in Settings) asks launchd to start
    /// the agent once it has gone, so the icon is supervised again.
    static func now() {
        let environment = ProcessInfo.processInfo.environment
        if environment["XPC_SERVICE_NAME"] == Companion.menuLabel { exit(exitCode) }
        // Not a development copy, and the agent is registered.
        guard Bundle.main.bundleIdentifier == Companion.menuLabel, environment["PUREMOUSE_DAEMON"] == nil,
              FileManager.default.fileExists(atPath: Paths.launchAgent(Companion.menuLabel).path)
        else { return }
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The agent's copy would hand over to this one while it still runs.
        starter.arguments = ["-c", "sleep 0.5; exec /bin/launchctl kickstart gui/\(getuid())/\(Companion.menuLabel)"]
        guard (try? starter.run()) != nil else { return }
        exit(0)
    }
}
