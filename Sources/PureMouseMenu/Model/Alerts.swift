import AppKit
import PureMouseAppSupport

extension Lifecycle {
    /// Runs the command and shows an alert if it fails.
    static func perform(_ command: Command, then success: @escaping @MainActor () -> Void = {}) {
        run(command) { result in
            switch result {
            case .success: success()
            case .failure(let error): Alerts.show("PureMouse could not do that", error.description)
            }
        }
    }
}

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
