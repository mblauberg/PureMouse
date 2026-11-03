import Foundation
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
    /// Bluetooth mice seen but not usable until Input Monitoring is allowed, by name.
    var waitingForInputMonitoring: [String] = []
    var configError = false
    var logiOptionsRunning = false
    var smoothScrolling = true
    var readOnly = false
    var dpiPresets: [Int] = []
    /// The mouse's own DPI, else the configured one.
    var currentDPI: Int?
    /// The live mouse's sensor steps (empty when unknown).
    var dpiSteps: [Int] = []
    /// The app in front as the menu opened (read once, never watched); nil when not read.
    var frontmost: FrontmostApp?
    /// A newer release found by the daily check (`UpdateReminders.offer`), not skipped.
    var update: UpdateOffer?
    /// What the Update row is doing (`AppController.installUpdate`).
    var installing: UpdateInstallState = .idle

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

/// The frontmost app as the menu opens: its bundle identifier and name, passed in so the plan needs
/// no `NSWorkspace`. A status item's menu does not activate PureMouse, so this is still the app the
/// person was using.
struct FrontmostApp: Equatable {
    var bundleID: String?
    var name: String?

    /// Apps with no settings of their own to offer: the Finder and the Dock never own the buttons or
    /// the scroll wheel the way a document app does, and PureMouse's own bundles (the daemon, the menu
    /// app and the Settings helper) are what the menu belongs to.
    private static let excluded: Set<String> = ["com.apple.finder", "com.apple.dock"]
    private static let pureMouse = "io.github.mblauberg.puremouse"

    /// The bundle identifier "Settings for <app>…" would configure; nil when the app is excluded or
    /// has none.
    var configurable: String? {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let key = id.lowercased()
        if Self.excluded.contains(key) || key == Self.pureMouse || key.hasPrefix(Self.pureMouse + ".") { return nil }
        return id
    }

    /// The name the row shows: the app's name, else its bundle identifier.
    var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (bundleID ?? "") : trimmed
    }
}

/// Where an update chosen from the menu stands. Kept in memory only: a relaunch starts idle.
enum UpdateInstallState: Equatable {
    case idle
    /// Downloading, checking and swapping; the row is disabled.
    case installing
    /// The new app is on disk. The row is gone, since the version it offers is installed.
    case installed
    /// Nothing was replaced. `reason` is one line; `retry` is whether trying again could work.
    case failed(reason: String, retry: Bool)
}

/// What choosing a row does; `StatusMenu` maps each to the model or `AppController`.
enum MenuAction {
    case openSettings(SettingsPane?)
    /// Apps, on the sheet of the app with this bundle identifier.
    case openAppSettings(String)
    /// Pointer's presets sheet.
    case editPresets
    case openReleases
    /// The release page of a newer version.
    case openUpdate(URL)
    /// Asks, then downloads, verifies and installs the newer version.
    case installUpdate
    case skipUpdate
    case openPrivacy(PrivacyPane)
    /// Asks Logi Options+ to quit (`LogiOptionsAction.quit`).
    case quitLogiOptions
    /// Opens Login Items in System Settings, where its login item is removed.
    case openLoginItems
    case toggleSmoothScrolling
    case setDPI(Int)
    case start
    case setPaused(Bool)
    case reloadConfig
    /// Starts a fresh apply where the settings are not applied.
    case applySettingsAgain
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
    /// A key equivalent with ⌘.
    var key = ""
    var checked = false
    /// Shown with a warning triangle in the checkmark column.
    var attention = false
    var enabled = true
    /// Replaces the item before it while ⌥ is held (the renderer adds ⌥ to its modifiers). AppKit
    /// folds an alternate into the item before it only when both share the key equivalent.
    var alternate = false
    var action: MenuAction?
    var submenu: [MenuRow]?
}

enum MenuPlan {
    static let offSubtitle = "The mouse works as it does without PureMouse"
    static let waitingSubtitle = "Bluetooth · Waiting for Input Monitoring"

    /// The rows in order. `option`: ⌥ was held as the menu opened, which adds Reload Config and
    /// Show Log in Finder (the headers' and Hide Menu Bar Icon's alternates are always there).
    /// The config applies on save; Reload Config is the recovery for what saving cannot redo.
    static func rows(for state: MenuState, option: Bool) -> [MenuRow] {
        var rows: [MenuRow] = []
        let running = state.daemonRunning
        if !running {
            rows += header(title: "PureMouse Is Off", subtitle: offSubtitle)
        } else {
            if state.devices.isEmpty, state.waitingForInputMonitoring.isEmpty {
                // While paused the daemon drops its sessions, so it reports no devices.
                rows += state.paused
                    ? header(title: "PureMouse Is Paused", subtitle: offSubtitle)
                    : header(title: "No Mouse Connected", subtitle: "Turn on your mouse or check the receiver")
            }
            for name in state.waitingForInputMonitoring {
                rows += header(title: name, subtitle: waitingSubtitle)
            }
            for device in state.devices {
                let prefix = Standby(paused: state.paused, away: state.away).map { "\($0.title) · " } ?? ""
                rows += header(title: device.name, subtitle: prefix + StatusText.subtitle(device),
                               detail: StatusText.detail(device, version: state.version))
            }
        }
        rows += attentionRows(state)
        rows += updateRows(state)

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
        if let id = state.frontmost?.configurable, let app = state.frontmost {
            rows.append(.item(MenuItem(title: "Settings for \(app.title)…", action: .openAppSettings(id))))
        }
        rows.append(.item(MenuItem(title: "Quit PureMouse", key: "q", action: .quit)))
        // ⌥⌘Q: AppKit pairs an alternate with Quit only when both share "q" (docs/ui-language.md).
        rows.append(.item(MenuItem(title: "Hide Menu Bar Icon", key: "q", alternate: true, action: .hideMenuBarIcon)))
        return rows
    }

    /// What VoiceOver reads for a header: its title and lines, with the " · " that separates the
    /// parts of a line spoken as commas.
    static func spokenHeader(title: String, lines: [String]) -> String {
        ([title] + lines).joined(separator: ", ").replacing(" · ", with: ", ")
    }

    /// The warning rows; with PureMouse off, only a status too new to read.
    static func attentionRows(_ state: MenuState) -> [MenuRow] {
        var rows: [MenuRow] = []
        if state.statusTooNew { rows.append(attention("Update PureMouse", .openReleases)) }
        guard state.daemonRunning else { return rows }
        if state.accessibilityMissing {
            rows.append(attention("Allow Accessibility Access", .openPrivacy(.accessibility)))
        }
        if state.inputMonitoringMissing, state.hasBluetoothDevice || !state.waitingForInputMonitoring.isEmpty {
            rows.append(attention("Allow Input Monitoring", .openPrivacy(.inputMonitoring)))
        }
        if state.configError { rows.append(attention("Fix Config File…", .openSettings(.tab(.general)))) }
        if state.devices.contains(where: { $0.applied?.state == .notApplied }) {
            rows.append(attention("Apply Settings Again", .applySettingsAgain))
        }
        if state.logiOptionsRunning {
            // Quit carries the warning; the login item is its follow-up, so a plain row under it.
            rows.append(attention(LogiOptionsAction.quit.title, .quitLogiOptions))
            rows.append(.item(MenuItem(title: LogiOptionsAction.openLoginItems.title, action: .openLoginItems)))
        }
        return rows
    }

    /// A newer release: plain rows (no warning, no badge on the icon). Update to 1.2.3… asks, then
    /// installs; while that runs it is disabled and says so. After a failure the row gives its one-line
    /// reason and the release page (the manual way), and offers another try where one could work.
    /// Skip This Version stays under them until PureMouse is updated or the version is skipped.
    static func updateRows(_ state: MenuState) -> [MenuRow] {
        guard let update = state.update else { return [] }
        let skip = MenuRow.item(MenuItem(title: UpdateOffer.skipTitle, action: .skipUpdate))
        switch state.installing {
        case .idle:
            return [.item(MenuItem(title: update.menuTitle, action: .installUpdate)), skip]
        case .installing:
            return [.item(MenuItem(title: update.installingTitle, enabled: false)), skip]
        case .installed:
            return []
        case .failed(let reason, let retry):
            var rows = [MenuRow.item(MenuItem(title: reason, enabled: false))]
            if retry { rows.append(.item(MenuItem(title: update.menuTitle, action: .installUpdate))) }
            rows.append(.item(MenuItem(title: UpdateOffer.viewTitle, action: .openUpdate(update.page))))
            return rows + [skip]
        }
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
        rows.append(.item(MenuItem(title: presets.isEmpty ? "Add Presets…" : "Edit Presets…", action: .editPresets)))
        return rows
    }
}

extension MenuState {
    @MainActor init(model: AppModel) {
        let live = model.liveDevice
        self.init(daemonRunning: model.daemonRunning, paused: model.paused, away: model.status?.away == true,
                  statusTooNew: model.statusTooNew, version: model.status?.version ?? "dev", devices: model.devices,
                  accessibilityMissing: model.accessibilityMissing, inputMonitoringMissing: model.inputMonitoringMissing,
                  hasBluetoothDevice: model.hasBluetoothDevice,
                  waitingForInputMonitoring: model.waitingForInputMonitoring.map(\.name), configError: model.configError != nil,
                  logiOptionsRunning: model.logiOptionsRunning, smoothScrolling: model.config.smoothScrollEnabled,
                  readOnly: model.readOnly, dpiPresets: model.config.dpiPresets,
                  // The mouse's own value first: a Cycle Pointer Speed press changes it, not the config.
                  currentDPI: live?.dpi ?? model.config.int(["dpi"]), dpiSteps: live?.dpiSteps ?? [])
    }
}
