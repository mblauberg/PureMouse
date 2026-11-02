import AppKit
import PureMouseAppSupport

@MainActor
enum Alerts {
    static func show(_ message: String, _ info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
        AppController.shared?.relaunchIfIdle() // it waited for this alert
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
        AppController.shared?.relaunchIfIdle()
        return confirmed
    }
}
