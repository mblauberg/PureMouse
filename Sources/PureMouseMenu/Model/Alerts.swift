import AppKit
import PureMouseAppSupport

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

    /// The one question about automatic update checks (`UpdateQuestion`): Check Automatically is the
    /// default button.
    static func updateQuestion() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = UpdateQuestion.title
        alert.informativeText = UpdateQuestion.message
        alert.addButton(withTitle: UpdateQuestion.accept)
        alert.addButton(withTitle: UpdateQuestion.decline)
        return alert
    }

    /// The alert behind "Update to 1.2.3…": Update and Relaunch is the default button.
    static func updateConfirmation(_ offer: UpdateOffer) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = offer.confirmTitle
        alert.informativeText = UpdateOffer.confirmMessage
        alert.addButton(withTitle: UpdateOffer.confirmAccept)
        alert.addButton(withTitle: UpdateOffer.confirmDecline)
        return alert
    }

    static func confirmUpdate(_ offer: UpdateOffer) -> Bool {
        NSApp.activate()
        return updateConfirmation(offer).runModal() == .alertFirstButtonReturn
    }

    /// Asks it; true for Check Automatically. Ending the alert any other way cannot happen, and a
    /// no answer is stored like Don't Check.
    static func askAboutUpdates() -> Bool {
        NSApp.activate()
        return updateQuestion().runModal() == .alertFirstButtonReturn
    }
}
