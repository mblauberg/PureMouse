import AppKit
import PureMouseAppSupport

@MainActor
public enum Alerts {
    public static func show(_ message: String, _ info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    /// A confirmation with a destructive default; returns true to go ahead.
    static func confirm(_ message: String, _ info: String, action: String, window: NSWindow? = NSApp.keyWindow) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return confirmed
    }
}
