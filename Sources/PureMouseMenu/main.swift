// The menu bar app: status item and menu. It edits the config and talks to the daemon through the
// companion channel; it never opens HID devices, and Settings is an app of its own (the Settings
// helper). See docs/companion.md.
import AppKit
import PureMouseAppSupport

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Single instance: a second launch (the Finder, `open`) opens Settings, then exits; the
    // running copy keeps the icon.
    if let bundleID = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
           // LaunchServices learns of an exit late: a copy that has just quit may still be listed.
           .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }) {
        SettingsLauncher.shared.open(pane: ShowRequest.consume()?.pane) { exit(0) }
        app.run()
    }

    let controller = AppController()
    app.delegate = controller
    app.run()
    _ = controller
}
