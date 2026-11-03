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

    private var shown: (look: StatusIcon.Look, badge: StatusIcon.Badge, label: String)?

    /// Redraws the glyph and relabels it only when what they show has changed.
    func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = MenuState(model: model)
        let badge: StatusIcon.Badge = state.needsAttention ? .attention : model.lowBattery ? .battery : .none
        let look = StatusIcon.look(daemonRunning: state.daemonRunning, paused: state.paused)
        let label = StatusText.accessibilityLabel(state, primary: model.primaryDevice)
        if shown?.look != look || shown?.badge != badge {
            button.image = StatusIcon.image(look: look, badge: badge)
        }
        if shown?.label != label {
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        shown = (look, badge, label)
    }

    // MARK: Building

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshLiveness()
        model.reloadConfig()
        var option = NSEvent.modifierFlags.contains(.option)
        #if DEBUG
        option = option || DevHooks.holdsOption
        #endif
        var state = MenuState(model: model)
        #if DEBUG
        DevHooks.fixture(&state)
        #endif
        state.update = app.updates.offer
        state.installing = app.installState
        // Read once, as the menu opens: choosing the menu does not activate PureMouse, so this is
        // still the app the person was using. No observer, no timer.
        let front = NSWorkspace.shared.frontmostApplication
        state.frontmost = FrontmostApp(bundleID: front?.bundleIdentifier, name: front?.localizedName)
        var rows = MenuPlan.rows(for: state, option: option)
        #if DEBUG
        rows = DevHooks.submenu(rows)
        #endif
        MenuRenderer { [weak self] in self?.perform($0) }.fill(menu, with: rows)
        #if DEBUG
        // AppKit shows an alternate only for a real ⌥ at the click: a screenshot shows them in place of
        // the items they replace.
        if DevHooks.holdsOption {
            for (index, item) in menu.items.enumerated() where item.isAlternate && index > 0 {
                menu.item(at: index - 1)?.isHidden = true
                item.isAlternate = false
            }
        }
        #endif
    }

    private func perform(_ action: MenuAction) {
        #if DEBUG
        // The two-mice fixture has keys no real config should gain entries for.
        if DevHooks.ignores(action) { return }
        #endif
        switch action {
        case .openSettings(let pane): app.showSettings(ShowRequest(pane: pane))
        case .openAppSettings(let id): app.showSettings(ShowRequest(app: id))
        case let .editPresets(device): app.showSettings(ShowRequest(sheet: .presets, device: device))
        case .openReleases: app.openReleases()
        case .openUpdate(let page): app.openUpdate(page)
        case .installUpdate: app.installUpdate()
        case .skipUpdate: app.skipUpdate()
        case .openPrivacy(let pane): app.openPrivacy(pane)
        case .quitLogiOptions: app.quitLogiOptions()
        case .openLoginItems: LogiOptionsAction.openLoginItems.url.map { NSWorkspace.shared.open($0) }
        case .toggleSmoothScrolling: model.update { $0.smoothScrollEnabled.toggle() }
        case .setDPI(let dpi): model.setDPI(dpi)
        case let .setDeviceDPI(dpi, key): model.setPointerSpeed(dpi, device: key)
        case .start: action.command.map { model.perform($0) }
        case .setPaused(let paused): model.setPaused(paused)
        case .reloadConfig: model.reloadDaemonConfig()
        case .applySettingsAgain: model.applySettingsAgain()
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
        if case .start = self { LoginAction.start.command } else { nil }
    }
}
