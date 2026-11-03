import AppKit
import PureMouseAppSupport

/// Asks Logi Options+ to quit, as its own Quit menu item would: `terminate()` sends the quit
/// request, never a signal, and nothing here starts the app. When an app has quit, the daemon is
/// asked to look again (its notice clears in place). It watches the app's `isTerminated` through
/// KVO, so nothing ticks, and holds one observation per process, dropped once it has quit.
/// Keep in step with `Sources/PureMouseMenu/LogiOptionsQuit.swift`:
/// the menu must not link SettingsUI, and AppSupport has no AppKit.
@MainActor
final class LogiOptionsQuit {
    static let shared = LogiOptionsQuit()
    private var watching = OneObservationEach<pid_t, NSKeyValueObservation>()

    func ask(then recheck: @escaping @MainActor () -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            LogiOptionsAction.isLogiOptions(bundleIdentifier: $0.bundleIdentifier)
        }
        for app in apps where app.terminate() {
            let pid = app.processIdentifier
            watching.start(pid) {
                app.observe(\.isTerminated) { [weak self] app, _ in
                    guard app.isTerminated else { return }
                    Task { @MainActor in
                        self?.watching.finish(pid)
                        recheck()
                    }
                }
            }
        }
        recheck()  // the agent may be one the system does not list as an app
    }
}
