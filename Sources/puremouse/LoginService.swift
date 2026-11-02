import Foundation
import PureMouseKit

/// The two things PureMouse runs: the daemon (this app's binary) and the menu bar app inside it.
enum Job: CaseIterable {
    case daemon, menu

    var label: String {
        switch self {
        case .daemon: Companion.daemonLabel
        case .menu: Companion.menuLabel
        }
    }
}

/// How the system keeps PureMouse's jobs: mechanism only. `LoginItem` owns the policy (which job
/// first, the hidden menu, who is calling) and talks to this, so the policy is tested against a
/// fake. The two axes are independent: registering a job makes it start at login without starting
/// it, loading starts it without registering it.
protocol LoginService {
    /// Names the mechanism in `login-status`.
    var name: String { get }
    /// Whether the job starts at login.
    func status(_ job: Job) -> JobStatus
    /// Whether the job is running now.
    func isLoaded(_ job: Job) -> Bool
    /// Makes the job start at login from now on, with `definition`; replaces an earlier
    /// registration. Does not start it, and leaves a running instance alone.
    func register(_ job: Job, _ definition: [String: Any]) throws
    /// Starts the job now. A registered job runs as registered (`definition` is not used);
    /// otherwise it runs from `definition` without being registered, so it is not started at the
    /// next login.
    func load(_ job: Job, _ definition: [String: Any]) throws
    /// Stops the job starting at login. Does not stop a running instance.
    func unregister(_ job: Job) throws
    /// Stops the job if it is running, waiting for it to finish restoring the mouse. Returns
    /// whether it was running. Leaves the registration alone.
    @discardableResult func stop(_ job: Job) throws -> Bool
}

/// Launch agents: plists in `~/Library/LaunchAgents` (what registered means), bootstrapped into and
/// booted out of the user's launchd domain.
struct LaunchdAgentService: LoginService {
    var name: String { "launchd" }

    /// Where registered jobs live; launchd bootstraps them at login.
    var agents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
    /// Where a job started without registering is defined. launchd loads nothing from here at
    /// login.
    var transient = Companion.directory.appending(path: "launchd")

    private func plistURL(_ job: Job) -> URL { agents.appending(path: "\(job.label).plist") }
    private func transientURL(_ job: Job) -> URL { transient.appending(path: "\(job.label).plist") }
    private func target(_ job: Job) -> String { "gui/\(getuid())/\(job.label)" }

    func status(_ job: Job) -> JobStatus {
        FileManager.default.fileExists(atPath: plistURL(job).path) ? .enabled : .notRegistered
    }

    func isLoaded(_ job: Job) -> Bool { launchctl("print", target(job)).status == 0 }

    func register(_ job: Job, _ definition: [String: Any]) throws {
        try write(definition, to: plistURL(job))
    }

    func load(_ job: Job, _ definition: [String: Any]) throws {
        var plist = plistURL(job)
        if status(job) == .notRegistered {
            plist = transientURL(job)
            try write(definition, to: plist)
        }
        let (status, output) = launchctl("bootstrap", "gui/\(getuid())", plist.path)
        guard status == 0 else { throw Failure.bootstrap(output) }
    }

    func unregister(_ job: Job) throws {
        do {
            try FileManager.default.removeItem(at: plistURL(job))
        } catch CocoaError.fileNoSuchFile {
            // Never registered, or already removed.
        }
    }

    @discardableResult
    func stop(_ job: Job) throws -> Bool {
        let jobTarget = target(job)
        // Whether or not it was running, a definition kept for `load` goes: booting out needs only
        // the label.
        defer { try? FileManager.default.removeItem(at: transientURL(job)) }
        guard isLoaded(job) else { return false }
        let (_, output) = launchctl("bootout", jobTarget)
        for _ in 0..<50 {
            if !isLoaded(job) { return true }
            usleep(100_000)
        }
        throw Failure.stillRunning(target: jobTarget, output: output)
    }

    private func write(_ definition: [String: Any], to plist: URL) throws {
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: plist)
    }

    private func launchctl(_ arguments: String...) -> (status: Int32, output: String) {
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

    enum Failure: Error, CustomStringConvertible {
        case bootstrap(String), stillRunning(target: String, output: String)

        var description: String {
            switch self {
            case .stillRunning(let target, let output):
                "the running PureMouse did not stop (\(output)); try `launchctl bootout \(target)`"
            case .bootstrap(let output):
                "launchd would not start PureMouse (\(output)); check it is allowed under System Settings › General › Login Items"
            }
        }
    }
}
