import AppKit
import PureMouseAppSupport
import PureMouseKit

/// The status item and its plain `NSMenu`, rebuilt each time it opens (`menuNeedsUpdate`), so it
/// costs nothing while closed.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let app: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel, app: AppController) {
        self.model = model
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS remembers where the user put the icon under this name.
        statusItem.autosaveName = "PureMouseStatusItem"
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    #if DEBUG || DEVHOOKS
    func open(appearance: NSAppearance?) {
        menu.appearance = appearance
        statusItem.button?.performClick(nil)
    }

    func close() { menu.cancelTracking() }
    #endif

    private var shown: (dimmed: Bool, badge: StatusIcon.Badge, label: String)?

    /// Redraws the glyph and relabels it only when what they show has changed.
    func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = MenuState(model: model)
        let badge: StatusIcon.Badge = state.needsAttention ? .attention : model.lowBattery ? .battery : .none
        let dimmed = !state.daemonRunning || state.paused
        let label = StatusText.accessibilityLabel(state, primary: model.primaryDevice)
        if shown?.dimmed != dimmed || shown?.badge != badge {
            button.image = StatusIcon.image(dimmed: dimmed, badge: badge)
        }
        if shown?.label != label {
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        shown = (dimmed, badge, label)
    }

    // MARK: Building

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshLiveness()
        model.reloadConfig()
        let option = NSEvent.modifierFlags.contains(.option)
        let rows = MenuPlan.rows(for: MenuState(model: model), option: option)
        MenuRenderer { [weak self] in self?.perform($0) }.fill(menu, with: rows)
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .openSettings(let pane): app.showSettings(pane: pane)
        case .openReleases: app.openReleases()
        case .openPrivacy(let pane): app.openPrivacy(pane)
        case .toggleSmoothScrolling: model.update { $0.smoothScrollEnabled.toggle() }
        case .setDPI(let dpi): model.setDPI(dpi)
        case .start: model.perform(.register)
        case .setPaused(let paused): model.setPaused(paused)
        case .reloadConfig: model.reloadDaemonConfig()
        case .showLog: NSWorkspace.shared.activateFileViewerSelecting([model.locations.log])
        case .quit: app.quitAll()
        case .hideMenuBarIcon: app.hideMenuBarIcon()
        }
    }
}
