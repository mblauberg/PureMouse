// The Settings helper, `PureMouse Settings.app`: the Settings window as an app of its own, started
// on demand by the menu bar app and gone once its window closes, so the resident menu bar app
// never holds AppKit's and SwiftUI's window memory (docs/adr/0009-settings-helper-app.md).
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Single instance: a second launch brings the running one forward. A pane asked for is in
    // `show-settings`, and its doorbell has already reached the running one.
    if let bundleID = Bundle.main.bundleIdentifier,
       let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
           .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
        app.yieldActivation(to: running)
        running.activate()
        exit(0)
    }

    let controller = SettingsApp()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
    _ = controller
}
