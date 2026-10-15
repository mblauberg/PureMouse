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
           // LaunchServices learns of an exit late: a predecessor that just quit to relaunch
           // (`Relaunch`) may still be listed.
           .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }) {
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
