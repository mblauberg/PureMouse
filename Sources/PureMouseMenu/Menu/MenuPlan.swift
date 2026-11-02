import PureMouseAppSupport
import PureMouseKit

/// What the status menu shows, decided without AppKit so every row can be tested. `StatusMenu`
/// renders the rows into `NSMenuItem`s each time the menu opens.
struct MenuState {
    var daemonRunning = false
    var paused = false
    /// The pointer is on another Mac (Universal Control).
    var away = false
    var statusTooNew = false
    /// The daemon's version, for the ⌥ detail line.
    var version = "dev"
    var devices: [Status.Device] = []
    var accessibilityMissing = false
    var inputMonitoringMissing = false
    var hasBluetoothDevice = false
    var configError = false
    var logiOptionsRunning = false
    var smoothScrolling = true
    var readOnly = false
    var dpiPresets: [Int] = []
    /// The mouse's own DPI, else the configured one.
    var currentDPI: Int?
    /// The live mouse's sensor steps (empty when unknown).
    var dpiSteps: [Int] = []

    /// The status item badges exactly what the menu flags.
    var needsAttention: Bool { !MenuPlan.attentionRows(self).isEmpty }
}

/// Why a running PureMouse leaves the mouse alone, paused before away. The menu's device header
/// and the status item's spoken label both say it.
enum Standby {
    case paused, away

    init?(paused: Bool, away: Bool) {
        if paused { self = .paused } else if away { self = .away } else { return nil }
    }

    var title: String {
        switch self {
        case .paused: "Paused"
        case .away: "On another Mac"
        }
    }

    var spoken: String {
        switch self {
        case .paused: "paused"
        case .away: "on another Mac"
        }
    }
}

/// What choosing a row does; `StatusMenu` maps each to the model or `AppController`.
enum MenuAction {
    case openSettings(SettingsPane?)
    case openReleases
    case openPrivacy(PrivacyPane)
    case toggleSmoothScrolling
    case setDPI(Int)
    case start
    case setPaused(Bool)
    case reloadConfig
    case showLog
    case quit
    case hideMenuBarIcon
}

enum MenuRow {
    /// A device header: bold title, secondary lines, glyph; choosing it opens Settings. An
    /// alternate (⌥) adds the detail line.
    case header(title: String, lines: [String], alternate: Bool)
    case separator
    case item(MenuItem)
}

struct MenuItem {
    var title: String
    /// A key equivalent with ⌘ (and ⌥ when `withOption`).
    var key = ""
    var withOption = false
    var checked = false
    /// Shown with a warning triangle in the checkmark column.
    var attention = false
    var enabled = true
    /// Replaces the item before it while ⌥ is held.
    var alternate = false
    var action: MenuAction?
    var submenu: [MenuRow]?
}

enum MenuPlan {
    static let offSubtitle = "The mouse works as it does without PureMouse"

    /// The rows in order. `option`: ⌥ was held as the menu opened, which adds Reload Config and
    /// Show Log in Finder (the headers' and Hide Menu Bar Icon's alternates are always there).
    static func rows(for state: MenuState, option: Bool) -> [MenuRow] {
        var rows: [MenuRow] = []
        let running = state.daemonRunning
        if !running {
            rows += header(title: "PureMouse Is Off", subtitle: offSubtitle)
        } else {
            if state.devices.isEmpty {
                // While paused the daemon drops its sessions, so it reports no devices.
                rows += state.paused
                    ? header(title: "PureMouse Is Paused", subtitle: offSubtitle)
                    : header(title: "No Mouse Connected", subtitle: "Turn on your mouse or check the receiver")
            }
            for device in state.devices {
                let prefix = Standby(paused: state.paused, away: state.away).map { "\($0.title) · " } ?? ""
                rows += header(title: device.name, subtitle: prefix + StatusText.subtitle(device),
                               detail: StatusText.detail(device, version: state.version))
            }
        }
        rows += attentionRows(state)

        rows.append(.separator)
        rows.append(.item(MenuItem(title: "Smooth Scrolling", checked: state.smoothScrolling,
                                   enabled: running && !state.readOnly, action: .toggleSmoothScrolling)))
        rows.append(.item(MenuItem(title: "Pointer Speed", enabled: running, submenu: pointerRows(state))))

        // Start, Pause and Resume share one slot, so nothing below them moves between states.
        rows.append(.separator)
        if !running {
            rows.append(.item(MenuItem(title: "Start PureMouse", action: .start)))
        } else {
            let paused = state.paused
            rows.append(.item(MenuItem(title: paused ? "Resume PureMouse" : "Pause PureMouse", action: .setPaused(!paused))))
            if option {
                rows.append(.item(MenuItem(title: "Reload Config", action: .reloadConfig)))
                rows.append(.item(MenuItem(title: "Show Log in Finder", action: .showLog)))
            }
        }

        rows.append(.separator)
        rows.append(.item(MenuItem(title: "Settings…", key: ",", action: .openSettings(nil))))
        rows.append(.item(MenuItem(title: "Quit PureMouse", key: "q", action: .quit)))
        rows.append(.item(MenuItem(title: "Hide Menu Bar Icon", key: "q", withOption: true, alternate: true,
                                   action: .hideMenuBarIcon)))
        return rows
    }

    /// The warning rows; with PureMouse off, only a status too new to read.
    static func attentionRows(_ state: MenuState) -> [MenuRow] {
        var rows: [MenuRow] = []
        if state.statusTooNew { rows.append(attention("Update the Menu Bar App…", .openReleases)) }
        guard state.daemonRunning else { return rows }
        if state.accessibilityMissing {
            rows.append(attention("Allow Accessibility Access…", .openPrivacy(.accessibility)))
        }
        if state.inputMonitoringMissing, state.hasBluetoothDevice {
            rows.append(attention("Allow Input Monitoring…", .openPrivacy(.inputMonitoring)))
        }
        if state.configError { rows.append(attention("Fix Config Error…", .openSettings(.general))) }
        if state.logiOptionsRunning { rows.append(attention("Quit Logi Options+…", .openSettings(.general))) }
        return rows
    }

    /// The header, and with a detail line its ⌥ alternate.
    private static func header(title: String, subtitle: String, detail: String? = nil) -> [MenuRow] {
        var rows = [MenuRow.header(title: title, lines: [subtitle], alternate: false)]
        if let detail { rows.append(.header(title: title, lines: [subtitle, detail], alternate: true)) }
        return rows
    }

    private static func attention(_ title: String, _ action: MenuAction) -> MenuRow {
        .item(MenuItem(title: title, attention: true, action: action))
    }

    private static func pointerRows(_ state: MenuState) -> [MenuRow] {
        var rows: [MenuRow] = []
        let presets = state.dpiPresets
        // A preset off the sensor's list runs at its nearest step, as the daemon snaps it.
        let selected = presets.first { DPIPresets.snap($0, to: state.dpiSteps) == state.currentDPI }
        for preset in presets {
            rows.append(.item(MenuItem(title: Format.dpi(preset), checked: preset == selected,
                                       enabled: !state.readOnly, action: .setDPI(preset))))
        }
        if let current = state.currentDPI, selected == nil {
            rows.append(.item(MenuItem(title: presets.isEmpty ? Format.dpi(current) : "Custom: \(Format.dpi(current))",
                                       checked: true, enabled: false)))
        }
        if !rows.isEmpty { rows.append(.separator) }
        rows.append(.item(MenuItem(title: presets.isEmpty ? "Add Presets…" : "Edit Presets…", action: .openSettings(.pointer))))
        return rows
    }
}

extension MenuState {
    @MainActor init(model: AppModel) {
        let live = model.liveDevice
        self.init(daemonRunning: model.daemonRunning, paused: model.paused, away: model.status?.away == true,
                  statusTooNew: model.statusTooNew, version: model.status?.version ?? "dev", devices: model.devices,
                  accessibilityMissing: model.accessibilityMissing, inputMonitoringMissing: model.inputMonitoringMissing,
                  hasBluetoothDevice: model.hasBluetoothDevice, configError: model.configError != nil,
                  logiOptionsRunning: model.logiOptionsRunning, smoothScrolling: model.config.smoothScrollEnabled,
                  readOnly: model.readOnly, dpiPresets: model.config.dpiPresets,
                  // The mouse's own value first: a Cycle Pointer Speed press changes it, not the config.
                  currentDPI: live?.dpi ?? model.config.int(["dpi"]), dpiSteps: live?.dpiSteps ?? [])
    }
}
