import AppKit
import PureMouseAppSupport

/// Asks Logi Options+ to quit, as its own Quit menu item would: `terminate()` sends the quit
/// request, never a signal, and nothing here starts the app. When an app has quit, the daemon is
/// asked to look again (its notice clears in place). It watches the app's `isTerminated` through
/// KVO, so nothing ticks. Settings has the same few lines: AppSupport, which they share, has no AppKit.
@MainActor
final class LogiOptionsQuit {
    static let shared = LogiOptionsQuit()
    private var watching: [NSKeyValueObservation] = []

    func ask(then recheck: @escaping @MainActor () -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            LogiOptionsAction.isLogiOptions(bundleIdentifier: $0.bundleIdentifier)
        }
        for app in apps where app.terminate() {
            watching.append(app.observe(\.isTerminated) { app, _ in
                guard app.isTerminated else { return }
                Task { @MainActor in recheck() }
            })
        }
        recheck()  // the agent may be one the system does not list as an app
    }
}
