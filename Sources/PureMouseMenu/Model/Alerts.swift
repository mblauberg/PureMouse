import AppKit

/// The same as `PureMouseSettingsUI.Alerts.show`, which this app does not link (it has no SwiftUI).
@MainActor
enum Alerts {
    static func show(_ message: String, _ info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
