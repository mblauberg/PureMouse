import Foundation
import PureMouseKit

/// After Settings closes, AppKit and SwiftUI keep about 35 MB that `malloc_zone_pressure_relief`
/// does not return, so the menu app starts over as a fresh copy, which shows only its icon.
/// `exec` in place is no good: LaunchServices keeps the old image's registration for the pid and
/// the new one never gets its status item.
@MainActor
enum Relaunch {
    /// EX_TEMPFAIL: "try again". Not a crash, and not a successful exit, so launchd restarts it.
    static let exitCode: Int32 = 75

    /// How long to wait before ending a process launched at `uptime`: launchd delays a respawn
    /// until 10 s after the last one (ThrottleInterval), and the icon would be gone meanwhile.
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
        // Not a development copy, and the agent is loaded (Quit PureMouse boots it out but keeps
        // its plist).
        let service = "gui/\(getuid())/\(Companion.menuLabel)"
        guard Bundle.main.bundleIdentifier == Companion.menuLabel, environment["PUREMOUSE_DAEMON"] == nil,
              launchctl(["print", service])
        else { return }
        // The agent's copy would hand over to this one while it still runs. In a session of its
        // own, so that nothing ending this process's group takes it along.
        guard spawnDetached("/bin/sh", ["-c", "sleep 0.5; exec /bin/launchctl kickstart \(service)"]) else { return }
        exit(0)
    }

    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func spawnDetached(_ path: String, _ arguments: [String]) -> Bool {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        return posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0
    }
}
