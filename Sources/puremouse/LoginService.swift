import Foundation
import PureMouseKit

/// The two things PureMouse runs: the daemon (this app's binary) and the menu bar app inside it.
enum Job {
    case daemon, menu

    var label: String {
        switch self {
        case .daemon: Companion.daemonLabel
        case .menu: Companion.menuLabel
        }
    }

    /// The menu bar app's executable inside its bundle.
    static func menuExecutable(in app: URL) -> URL {
        app.appending(path: "Contents/MacOS/PureMouseMenu")
    }
}

/// Where a job is in its life. A job that quit and is not restarted (the menu after Quit, whose
/// `KeepAlive` only covers crashes) stays loaded without a process.
enum JobState: Equatable {
    case notLoaded, loadedIdle, running
}

/// How the system keeps PureMouse's jobs: mechanism only. `LoginItem` owns the policy (which job
/// first, the hidden menu, who is calling) and talks to this, so the policy is tested against a
/// fake. The two axes are independent: registering a job makes it start at login without starting
/// it, starting it runs it without registering it.
///
/// Jobs are named by what to run, not by how a mechanism describes it: `location` is the daemon's
/// executable, or the menu bar app's bundle.
protocol LoginService {
    /// Names the mechanism in `login-status`.
    var name: String { get }
    /// Whether the job starts at login.
    func status(_ job: Job) -> JobStatus
    func state(_ job: Job) -> JobState
    /// Makes the job start at login from now on, running `location`; replaces an earlier
    /// registration. Does not start it, and leaves a running instance alone.
    func register(_ job: Job, at location: URL) throws
    /// Starts the job now unless it is running, and returns whether it did. A registered job's
    /// registration is first brought up to date with `location` (it stays registered); an
    /// unregistered job runs without being registered, so it is not started at the next login.
    @discardableResult func start(_ job: Job, at location: URL) throws -> Bool
    /// Stops the job starting at login. Does not stop a running instance.
    func unregister(_ job: Job) throws
    /// Stops the job if it is loaded, waiting for it to finish restoring the mouse. Returns
    /// whether it was loaded. Leaves the registration alone.
    @discardableResult func stop(_ job: Job) throws -> Bool
}

/// Launch agents: plists in `~/Library/LaunchAgents` (what registered means), bootstrapped into and
/// booted out of the user's launchd domain.
struct LaunchdAgentService: LoginService {
    /// Runs `launchctl` with the arguments; replaceable in tests.
    typealias Launchctl = ([String]) -> (status: Int32, output: String)

    var name: String { "launchd" }

    /// Where registered jobs live; launchd bootstraps them at login.
    private let agents: URL
    /// Where a job started without registering is defined. launchd loads nothing from here at
    /// login.
    private let transient: URL
    private let launchctl: Launchctl
    /// How many times `stop` looks for the job to be gone, and the pause between looks.
    private let stopPolls: Int
    private let stopPause: UInt32

    init(agents: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents"),
         transient: URL = Companion.directory.appending(path: "launchd"),
         launchctl: @escaping Launchctl = LaunchdAgentService.runLaunchctl,
         stopPolls: Int = 50, stopPause: UInt32 = 100_000) {
        self.agents = agents
        self.transient = transient
        self.launchctl = launchctl
        self.stopPolls = stopPolls
        self.stopPause = stopPause
    }

    // MARK: Definitions

    /// The launch agent for `job` running `location`.
    static func definition(_ job: Job, at location: URL) -> [String: Any] {
        switch job {
        case .daemon:
            [
                "Label": job.label,
                "ProgramArguments": [location.path, "run"],
                "RunAtLoad": true,
                // Restarted within seconds if it exits, including when it quits to pick up a new
                // permission (Daemon.pollPermissions).
                "KeepAlive": true,
                "ThrottleInterval": 3,
                "ProcessType": "Interactive",
            ]
        case .menu:
            [
                "Label": job.label,
                "ProgramArguments": [Job.menuExecutable(in: location).path],
                "RunAtLoad": true,
                // Relaunched after a crash, not after Quit.
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
                // Keeps about 8 MB off the menu's footprint once it has been used (docs/adr/0010).
                // Undocumented, so scripts/measure-menu.sh re-checks it per macOS release.
                "EnvironmentVariables": ["MallocSpaceEfficient": "1"],
            ]
        }
    }

    private func plistURL(_ job: Job) -> URL { agents.appending(path: "\(job.label).plist") }
    private func transientURL(_ job: Job) -> URL { transient.appending(path: "\(job.label).plist") }
    private func target(_ job: Job) -> String { "gui/\(getuid())/\(job.label)" }

    // MARK: LoginService

    func status(_ job: Job) -> JobStatus {
        FileManager.default.fileExists(atPath: plistURL(job).path) ? .enabled : .notRegistered
    }

    func state(_ job: Job) -> JobState { inspect(job).state }

    /// What launchd says about the job: the state, and the executable it was loaded to run. A job
    /// that is not loaded makes `launchctl print` fail. The report is nested blocks, and `state` is
    /// also a key inside some of them (the resource coalition's, for one), so only the lines at
    /// the job's own depth count: `state = running` there means a process exists.
    private func inspect(_ job: Job) -> (state: JobState, program: String?) {
        let (status, output) = launchctl(["print", target(job)])
        guard status == 0 else { return (.notLoaded, nil) }
        var depth = 0
        var running = false
        var program: String?
        var inArguments = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "}" {
                depth -= 1
                if depth == 1 { inArguments = false }
            } else if text.hasSuffix("{") {
                if depth == 1 { inArguments = text == "arguments = {" }
                depth += 1
            } else if depth == 1, text.hasPrefix("state = ") {
                running = text == "state = running"
            } else if inArguments, depth == 2, program == nil, !text.isEmpty {
                program = text
            }
        }
        return (running ? .running : .loadedIdle, program)
    }

    func register(_ job: Job, at location: URL) throws {
        try write(Self.definition(job, at: location), to: plistURL(job))
    }

    @discardableResult
    func start(_ job: Job, at location: URL) throws -> Bool {
        let (current, loadedProgram) = inspect(job)
        if current == .running { return false }
        let definition = Self.definition(job, at: location)
        var plist = plistURL(job)
        if status(job) == .enabled {
            // Registered from an older or moved copy: launchd would otherwise run that one.
            try write(definition, to: plist)
        } else if current == .notLoaded {
            plist = transientURL(job)
            try write(definition, to: plist)
        }
        if current == .loadedIdle {
            // A kickstart runs the definition launchd loaded, which names the old path if the app
            // moved since. Its executable (the first argument in `launchctl print`) is compared
            // with this build's; a job that differs, or that does not say, has no process, so
            // booting it out loses nothing and the current plist is bootstrapped in its place.
            let expected = (definition["ProgramArguments"] as? [String])?.first
            if loadedProgram == expected {
                let (status, output) = launchctl(["kickstart", target(job)])
                guard status == 0 else { throw Failure.kickstart(output) }
                return true
            }
            if status(job) == .notRegistered {
                plist = transientURL(job)
                try write(definition, to: plist)
            }
            try bootout(job)
        }
        let (status, output) = launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        guard status == 0 else { throw Failure.bootstrap(output) }
        return true
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
        // Whether or not it was loaded, a definition kept for `start` goes: booting out needs only
        // the label.
        defer { try? FileManager.default.removeItem(at: transientURL(job)) }
        guard state(job) != .notLoaded else { return false }
        try bootout(job)
        return true
    }

    /// Boots the job out and waits for launchd to let go of it.
    private func bootout(_ job: Job) throws {
        let jobTarget = target(job)
        let (_, output) = launchctl(["bootout", jobTarget])
        for _ in 0..<stopPolls {
            if state(job) == .notLoaded { return }
            usleep(stopPause)
        }
        throw Failure.stillRunning(target: jobTarget, output: output)
    }

    // MARK: Files and launchctl

    /// Written atomically, so launchd never reads half a plist while another command rewrites it.
    private func write(_ definition: [String: Any], to plist: URL) throws {
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            .write(to: plist, options: .atomic)
    }

    static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
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

    enum Failure: Error, CustomStringConvertible, Equatable {
        case bootstrap(String), kickstart(String), stillRunning(target: String, output: String)

        var description: String {
            switch self {
            case .stillRunning(let target, let output):
                "the running PureMouse did not stop (\(output)); try `launchctl bootout \(target)`"
            case .bootstrap(let output):
                "launchd would not start PureMouse (\(output)); check it is allowed under System Settings › General › Login Items"
            case .kickstart(let output):
                "launchd would not restart PureMouse (\(output))"
            }
        }
    }
}
