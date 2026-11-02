import AppKit
import Observation
import PureMouseAppSupport

/// What a pane may ask of the window around it.
@MainActor @Observable
final class SettingsContext {
    @ObservationIgnored weak var tabs: SettingsTabs?
    /// The sheet open over the pane, if any: a request can ask for one (`ShowRequest`), and the
    /// pane that owns it presents it.
    var sheet: SettingsSheet?

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
