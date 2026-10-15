// The menu bar app: status item, menu and Settings window. It edits the config and talks to the
// daemon through the companion channel; it never opens HID devices. See docs/companion.md.
import AppKit
import PureMouseKit
import notify

MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Single instance: a second launch hands over to the running one, which shows Settings.
    if let bundleID = Bundle.main.bundleIdentifier,
       let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
           .first(where: { $0.processIdentifier != getpid() }) {
        app.yieldActivation(to: running)
        ShowRequest.post()
        exit(0)
    }

    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
    _ = controller
}
