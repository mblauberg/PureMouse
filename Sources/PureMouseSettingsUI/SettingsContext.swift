import AppKit
import Observation
import PureMouseAppSupport
import PureMouseKit

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
    /// The latest ask to bring a Buttons row into view. It has an identity of its own, apart from the
    /// highlight on `card`: choosing the same part twice leaves `card.button` as it was, but is a new
    /// request, so the row scrolls into view again after the person has scrolled away.
    private(set) var rowRequest: RowRequest?
    /// The Scrolling section the device card sent the person to: Scrolling takes it, scrolls it into
    /// view and outlines it, and clears it (`ScrollingPane`).
    var arrival: ScrollingSection?

    var window: NSWindow? { tabs?.view.window }

    /// Applies the navigation part of `SettingsWindowController.show`, before activation or a
    /// sheet is presented. Only an actual page change takes a snapshot.
    func show(_ request: ShowRequest?) {
        let change = {
            if let pane = request?.pane { self.tabs?.open(pane) }
            if let app = request?.app { self.app = app }
        }
        if let pane = request?.pane, tabs?.changesPage(to: pane) == true {
            transition(change)
        } else {
            change()
        }
    }

    /// Apps consumes a request during layout, joining a tab transition if one is being made.
    /// Repeating the current app leaves its segment and any animation under way alone.
    func openRequested(in list: inout AppList, config: ConfigTree) {
        guard let app else { return }
        self.app = nil
        guard list.open != config.appKey(app) else { return }
        transition { list.add(app, in: config) }
    }

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
            requestRow(button)
        case .scrolling(let section):
            arrival = section
            if let selection = tabs?.mouse?.selection {
                selection.select(.scrolling)
            } else {
                tabs?.open(.mouse(.scrolling))
            }
        }
    }

    /// Asks Buttons to bring the row of `button` into view, even if it is the one already chosen.
    func requestRow(_ button: NamedButton) {
        rowRequest = RowRequest(id: (rowRequest?.id ?? 0) + 1, button: button)
    }

    /// Changes what the pane shows (an app's page, back to the list) as the window's one page
    /// transition: the content cross-fades as the frame moves (`SettingsTabs.transition`).
    func transition(_ change: () -> Void) {
        if let tabs { tabs.transition(change) } else { change() }
    }

    /// Fits the window to its pane once a change in the pane's height has laid out
    /// (`SettingsTabs.refit`).
    func refit() {
        DispatchQueue.main.async { [weak self] in self?.tabs?.refit() }
    }
}

/// A request to bring a Buttons row into view (`SettingsContext.requestRow`). Each one has a new `id`.
struct RowRequest: Equatable {
    let id: Int
    let button: NamedButton
}
