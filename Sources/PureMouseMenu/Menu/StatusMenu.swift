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
        var state = MenuState(model: model)
        state.update = app.updates.offer
        // Read once, as the menu opens: choosing the menu does not activate PureMouse, so this is
        // still the app the person was using. No observer, no timer.
        let front = NSWorkspace.shared.frontmostApplication
        state.frontmost = FrontmostApp(bundleID: front?.bundleIdentifier, name: front?.localizedName)
        let rows = MenuPlan.rows(for: state, option: option)
        MenuRenderer { [weak self] in self?.perform($0) }.fill(menu, with: rows)
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .openSettings(let pane): app.showSettings(ShowRequest(pane: pane))
        case .openAppSettings(let id): app.showSettings(ShowRequest(app: id))
        case .editPresets: app.showSettings(ShowRequest(sheet: .presets))
        case .openReleases: app.openReleases()
        case .openUpdate(let page): app.openUpdate(page)
        case .skipUpdate: app.skipUpdate()
        case .openPrivacy(let pane): app.openPrivacy(pane)
        case .toggleSmoothScrolling: model.update { $0.smoothScrollEnabled.toggle() }
        case .setDPI(let dpi): model.setDPI(dpi)
        case .start: action.command.map { model.perform($0) }
        case .setPaused(let paused): model.setPaused(paused)
        case .reloadConfig: model.reloadDaemonConfig()
        case .showLog: NSWorkspace.shared.activateFileViewerSelecting([model.locations.log])
        case .quit: app.quitAll()
        case .hideMenuBarIcon: app.hideMenuBarIcon()
        }
    }
}

extension MenuAction {
    /// The lifecycle command a row runs. Start PureMouse runs `start`, never `register`, so Open at
    /// login does not change as a side effect (docs/adr/0018-login-service-seam.md).
    var command: Lifecycle.Command? {
        if case .start = self { LoginAction.running(true).command } else { nil }
    }
}
