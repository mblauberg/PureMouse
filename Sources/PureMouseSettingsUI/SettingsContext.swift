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
    /// The app (by bundle identifier) whose sheet a request asks Apps to open: Apps takes it,
    /// listing the app if need be, and clears it.
    var app: String?
    /// The part of the device card chosen on Buttons (cleared on leaving Buttons or changing mouse).
    let card = CardSelection()
    /// The Scrolling section the device card sent the person to: Scrolling takes it, scrolls it into
    /// view and outlines it, and clears it (`ScrollingPane`).
    var arrival: ScrollingSection?

    var window: NSWindow? { tabs?.view.window }

    /// Shows a tab, or Mouse on a segment (the banner's "more notices" opens General).
    func open(_ pane: SettingsPane) {
        tabs?.open(pane)
    }

    /// What the device card does with a part: select a row on Buttons, or go to a section of
    /// Scrolling through the strip's own path (`MouseSelection.select`, which ends Find by Pressing
    /// and refits the window once). It changes no setting.
    func activate(_ destination: CardDestination) {
        switch destination {
        case .row(let button):
            card.select(button)
        case .scrolling(let section):
            arrival = section
            if let selection = tabs?.mouse?.selection {
                selection.select(.scrolling)
            } else {
                tabs?.open(.mouse(.scrolling))
            }
        }
    }

    /// Fits the window to its pane once a change in the pane's height has laid out
    /// (`SettingsTabs.refit`).
    func refit() {
        DispatchQueue.main.async { [weak self] in self?.tabs?.refit() }
    }
}
