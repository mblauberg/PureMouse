import AppKit

@MainActor
public enum Alerts {
    /// The menu bar app has its own copy (`PureMouseMenu.Alerts.show`): it does not link this module.
    public static func show(_ message: String, _ info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
