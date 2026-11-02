import AppKit
import PureMouseAppSupport

/// What a pane may ask of the window around it.
@MainActor
final class SettingsContext {
    weak var tabs: SettingsTabs?

    var window: NSWindow? { tabs?.view.window }

    /// Shows a tab, or Mouse on a segment (the banner's "more notices" opens General).
    func open(_ pane: SettingsPane) {
        tabs?.open(pane)
    }

    /// Fits the window to its pane once a change in the pane's height has laid out
    /// (`SettingsTabs.refit`).
    func refit() {
        DispatchQueue.main.async { [weak self] in self?.tabs?.refit() }
    }
}
