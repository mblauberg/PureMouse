import AppKit
import PureMouseAppSupport
import PureMouseKit

/// A running copy of the Settings helper, as `SettingsLauncher` sees it.
@MainActor
protocol RunningHelper: AnyObject {
    /// Running and not on its way out. LaunchServices lists a helper for a moment after its
    /// process exits, and opening it then brings forward the dead copy and starts none.
    var isAlive: Bool { get }
    func quit()
}

extension NSRunningApplication: RunningHelper {
    var isAlive: Bool { !isTerminated && kill(processIdentifier, 0) == 0 }
    func quit() { terminate() }
}

/// The alerts for a Settings helper that cannot be opened: what failed and what to do, with no path
/// or system text (`docs/ui-language.md`). The detail goes to the log.
enum SettingsAlert {
    static let missing = (title: "PureMouse Settings is missing", body: "Reinstall PureMouse to get it back.")
    static let couldNotOpen = (title: "PureMouse Settings could not open",
                               body: "Try again. If it keeps happening, restart your Mac.")
}

/// Opens Settings, which is an app of its own (`PureMouse Settings.app`, docs/adr/0009): the pane
/// goes in the `show-settings` file and the doorbell rings for a helper already running, then the
/// helper is opened, which starts it or brings it forward. Where it is: `SettingsLookup`.
@MainActor
final class SettingsLauncher {
    /// What the launcher needs from AppKit and the companion directory, so tests can stand in.
    struct System {
        var find: () -> Result<SettingsLookup.Helper, SettingsLookup.Failure>
        /// Writes the `ShowRequest` and rings the doorbell.
        var post: (SettingsPane?) -> Void
        /// Leaves the quit stamp a helper that starts late reads (`SettingsRequest.markQuit`).
        var markQuit: () -> Void
        /// Opens the app; the completion runs on the main actor with what LaunchServices returned.
        var open: (URL, @escaping @MainActor ((any RunningHelper)?, (any Error)?) -> Void) -> Void
        /// The running copies of the app at this location.
        var running: (URL) -> [any RunningHelper]
        var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
        var alert: (String, String) -> Void
    }

    static let shared = SettingsLauncher(system: .live)

    /// How long to wait before opening again when the first open found only a quitting helper.
    static let retryDelay: TimeInterval = 0.3
    /// How long Quit PureMouse waits for an open under way before going on without it. A helper
    /// that open starts later reads the quit stamp and quits at once.
    static let quitWait: TimeInterval = 3

    private let system: System
    /// A development build's bare helper binary, kept while it runs: without a bundle identifier
    /// nothing else stops a second copy.
    private var binary: Process?
    /// Opens sent to LaunchServices and not yet answered.
    private var pending = 0
    /// Quit PureMouse has begun: nothing more opens, and a helper an earlier open starts is quit.
    private var quitting = false
    private var whenSettled: [@MainActor () -> Void] = []
    /// Counts opens; a retry of an earlier one that a newer open has overtaken is dropped.
    private var generation = 0

    init(system: System) {
        self.system = system
    }

    /// `done` runs once the helper is open or the alert saying why not is answered.
    func open(pane: SettingsPane? = nil, then done: @escaping @MainActor () -> Void = {}) {
        guard !quitting else { return done() }
        generation += 1
        system.post(pane)
        switch system.find() {
        case .success(.app(let app)):
            launch(app, pane: pane, generation: generation, retries: 1, then: done)
        case .success(.binary(let url)):
            // A running copy has already heard the doorbell.
            if binary?.isRunning != true {
                let process = Process()
                process.executableURL = url
                do {
                    try process.run()
                    binary = process
                } catch {
                    NSLog("PureMouse: Settings did not start from %@: %@", url.path, error.localizedDescription)
                    system.alert(SettingsAlert.couldNotOpen.title, SettingsAlert.couldNotOpen.body)
                }
            }
            done()
        case .failure(let failure):
            NSLog("PureMouse: %@", failure.description)
            system.alert(SettingsAlert.missing.title, SettingsAlert.missing.body)
            done()
        }
    }

    private func launch(_ app: URL, pane: SettingsPane?, generation: Int, retries: Int,
                        then done: @escaping @MainActor () -> Void) {
        pending += 1
        system.open(app) { [self] helper, error in
            pending -= 1
            defer { if pending == 0 { settle() } }
            if quitting {
                helper?.quit()
                system.running(app).forEach { $0.quit() }
                return done()
            }
            if let error {
                NSLog("PureMouse: Settings did not open: %@", error.localizedDescription)
                system.alert(SettingsAlert.couldNotOpen.title, SettingsAlert.couldNotOpen.body)
                return done()
            }
            guard helper?.isAlive != true, !system.running(app).contains(where: \.isAlive), retries > 0 else { return done() }
            // A copy that was quitting answered; open again once LaunchServices has let it go, and
            // ask for the pane again, since that copy may have taken the request with it.
            pending += 1
            system.after(Self.retryDelay) { [self] in
                pending -= 1
                // Quitting, or a newer open has asked for its own pane and opened the helper.
                if quitting || generation != self.generation {
                    if pending == 0 { settle() }
                    return done()
                }
                system.post(pane)
                launch(app, pane: pane, generation: generation, retries: retries - 1, then: done)
            }
        }
    }

    /// Quit PureMouse: quits the helper, which saves its edits and cancels a select by pressing as
    /// it goes, then runs `done`. An open still under way is waited for (up to `quitWait`) and the
    /// helper it starts is quit too; one it starts after that finds the quit stamp and quits
    /// itself. So none is left running once PureMouse stops. Only the copy this app opens, found by
    /// its location: a development copy never quits an installed one.
    func quit(then done: @escaping @MainActor () -> Void) {
        quitting = true
        system.markQuit()
        quitRunning()
        guard pending > 0 else { return done() }
        var finished = false
        let once: @MainActor () -> Void = {
            guard !finished else { return }
            finished = true
            done()
        }
        whenSettled.append(once)
        system.after(Self.quitWait, once)
    }

    /// Quits the running helper; later opens still work (the footprint rig's "settings-close").
    func quitRunning() {
        switch system.find() {
        case .success(.app(let app)):
            system.running(app).forEach { $0.quit() }
        case .success(.binary), .failure:
            binary?.terminate() // SIGTERM, which the helper turns into a normal quit
        }
    }

    private func settle() {
        let waiting = whenSettled
        whenSettled = []
        waiting.forEach { $0() }
    }
}

extension SettingsLauncher.System {
    @MainActor static var live: Self { Self(
        find: {
            SettingsLookup.find(environment: ProcessInfo.processInfo.environment, bundle: Bundle.main.bundleURL,
                                executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                exists: { FileManager.default.isExecutableFile(atPath: $0.path) })
        },
        post: { ShowRequest.post(pane: $0) },
        markQuit: { SettingsRequest.markQuit() },
        open: { app, completion in
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: SettingsLookup.bundleIdentifier)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.environment = SettingsLookup.environment(from: ProcessInfo.processInfo.environment)
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { helper, error in
                DispatchQueue.main.async { completion(helper, error) }
            }
        },
        running: { app in
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        },
        after: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        },
        alert: { Alerts.show($0, $1) }) }
}
