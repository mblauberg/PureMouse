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
    /// Each mouse's resolved preset list by device key (its own entry over the top level).
    var mousePresets: [String: [Int]] = [:]
    /// The keys whose own `devices` entry sets `dpi` or `dpiPresets`: choosing a speed for such a
    /// mouse writes its entry, since the top level would not reach it.
    var dpiScoped: Set<String> = []
    /// The mouse's own DPI, else the configured one.
    var currentDPI: Int?
    /// The live mouse's sensor steps (empty when unknown).
    var dpiSteps: [Int] = []
    /// The app in front as the menu opened (read once, never watched); nil when not read.
    var frontmost: FrontmostApp?
    /// The frontmost app is turned off (`apps.<id>.enabled`), read from the config as the menu opens.
    var frontmostIsOff = false
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
    /// Pointer's presets sheet, in the scope the menu showed: under the mouse with this key, else
    /// All Mice.
    case editPresets(device: String?)
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
    /// Pointer Speed on the top level (every mouse).
    case setDPI(Int)
    /// Pointer Speed under `devices.<device>`, for that mouse only.
    case setDeviceDPI(Int, device: String)
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
    /// A section title in a submenu (`NSMenuItem.sectionHeader`): not a command, and not selectable.
    case sectionHeader(String)
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
    /// What VoiceOver reads when the title alone is ambiguous (a preset under a mouse's section).
    var spoken: String?
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
                let off = state.frontmostIsOff && !state.away && !state.paused ? state.frontmost?.title : nil
                rows += header(title: device.name, subtitle: prefix + StatusText.subtitle(device, offIn: off),
                               detail: StatusText.detail(device, version: state.version))
            }
        }
        rows += attentionRows(state)
        rows += updateRows(state)

        rows.append(.separator)
        rows.append(.item(MenuItem(title: "Smooth Scrolling", checked: state.smoothScrolling,
                                   enabled: running && !state.readOnly, action: .toggleSmoothScrolling)))
        // Disabled while every mouse answering reports it has no pointer speed to set.
        let noneOffers = state.devices.contains(where: \.online) && onlineMice(state.devices).isEmpty
        rows.append(.item(MenuItem(title: "Pointer Speed", enabled: running && !noneOffers, submenu: pointerRows(state))))

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

    /// The mice Pointer Speed sets, one per device key: those answering now that offer a pointer speed
    /// (`Status.Device.offers`), the first of each key (mice of one model share their settings), and
    /// every such mouse with no usable key. Only these count for sections.
    static func onlineMice(_ devices: [Status.Device]) -> [Status.Device] {
        var seen = Set<String>()
        return devices.filter { device in
            guard device.online, device.offers(\.dpi) else { return false }
            guard let key = device.deviceKey else { return true }
            return seen.insert(key).inserted
        }
    }

    private static func pointerRows(_ state: MenuState) -> [MenuRow] {
        let mice = onlineMice(state.devices)
        guard mice.count >= 2 else { return singleMouseRows(state, mouse: mice.first) }
        var rows: [MenuRow] = []
        for mouse in mice {
            // A mouse with no key has no entry of its own to write: writing the top level would move
            // the other mice, so it shows its speed and offers no presets.
            guard let key = mouse.deviceKey else {
                if let dpi = mouse.dpi {
                    rows.append(.sectionHeader(mouse.name))
                    let title = Format.dpi(dpi)
                    rows.append(.item(MenuItem(title: title, checked: true, enabled: false, spoken: "\(title), \(mouse.name)")))
                }
                continue
            }
            rows.append(.sectionHeader(mouse.name))
            let presets = state.mousePresets[key] ?? state.dpiPresets
            rows += presetRows(presets, current: mouse.dpi, steps: mouse.dpiSteps, readOnly: state.readOnly,
                               mouse: mouse.name) { .setDeviceDPI($0, device: key) }
            rows.append(editPresets(empty: presets.isEmpty, device: key, mouse: mouse.name))
        }
        return rows
    }

    /// One mouse: the rows as they always were. It writes the top level unless its own entry sets
    /// `dpi` or `dpiPresets`, which would otherwise hide the choice from it.
    private static func singleMouseRows(_ state: MenuState, mouse: Status.Device?) -> [MenuRow] {
        let key = mouse?.deviceKey
        let own = key.flatMap { state.dpiScoped.contains($0) ? $0 : nil }
        let presets = key.flatMap { state.mousePresets[$0] } ?? state.dpiPresets
        var rows = presetRows(presets, current: state.currentDPI, steps: state.dpiSteps, readOnly: state.readOnly,
                              mouse: nil) { dpi in
            own.map { .setDeviceDPI(dpi, device: $0) } ?? .setDPI(dpi)
        }
        if !rows.isEmpty { rows.append(.separator) }
        rows.append(editPresets(empty: presets.isEmpty, device: own, mouse: nil))
        return rows
    }

    /// One mouse's presets sheet, or (`device` nil) the top level's. `mouse`: the section's mouse, for
    /// VoiceOver ("Edit Presets for MX Master 3S").
    private static func editPresets(empty: Bool, device: String?, mouse: String?) -> MenuRow {
        let title = empty ? "Add Presets…" : "Edit Presets…"
        let spoken = mouse.map { "\(empty ? "Add Presets" : "Edit Presets") for \($0)" }
        return .item(MenuItem(title: title, spoken: spoken, action: .editPresets(device: device)))
    }

    /// The presets, the one the DPI is on checked, and "Custom: N" when it is on none. `mouse`: a
    /// section's mouse, whose name VoiceOver adds to each row ("1,600 DPI, MX Master 3S").
    private static func presetRows(_ presets: [Int], current: Int?, steps: [Int], readOnly: Bool, mouse: String?,
                                   action: (Int) -> MenuAction) -> [MenuRow] {
        func spoken(_ title: String) -> String? { mouse.map { "\(title), \($0)" } }
        var rows: [MenuRow] = []
        // A preset off the sensor's list runs at its nearest step, as the daemon snaps it.
        let selected = presets.first { DPIPresets.snap($0, to: steps) == current }
        for preset in presets {
            let title = Format.dpi(preset)
            rows.append(.item(MenuItem(title: title, checked: preset == selected, enabled: !readOnly,
                                       spoken: spoken(title), action: action(preset))))
        }
        if let current, selected == nil {
            let title = presets.isEmpty ? Format.dpi(current) : "Custom: \(Format.dpi(current))"
            rows.append(.item(MenuItem(title: title, checked: true, enabled: false, spoken: spoken(title))))
        }
        return rows
    }
}

extension MenuState {
    @MainActor init(model: AppModel) {
        let live = model.liveDevice
        let config = model.config
        // The mouse's own settings first, as the daemon resolves them; the top level without a key.
        let liveScope = live?.deviceKey.flatMap { ConfigScope.device($0) }
        var presets: [String: [Int]] = [:]
        var scoped: Set<String> = []
        for mouse in MenuPlan.onlineMice(model.devices) {
            guard let key = mouse.deviceKey, let scope = ConfigScope.device(key) else { continue }
            presets[key] = config.dpiPresets(in: scope)
            if config.isOverridden(["dpi"], in: scope) || config.isOverridden(["dpiPresets"], in: scope) { scoped.insert(key) }
        }
        self.init(daemonRunning: model.daemonRunning, paused: model.paused, away: model.status?.away == true,
                  statusTooNew: model.statusTooNew, version: model.status?.version ?? "dev", devices: model.devices,
                  accessibilityMissing: model.accessibilityMissing, inputMonitoringMissing: model.inputMonitoringMissing,
                  hasBluetoothDevice: model.hasBluetoothDevice,
                  waitingForInputMonitoring: model.waitingForInputMonitoring.map(\.name), configError: model.configError != nil,
                  logiOptionsRunning: model.logiOptionsRunning, smoothScrolling: model.config.smoothScrollEnabled,
                  readOnly: model.readOnly, dpiPresets: config.dpiPresets, mousePresets: presets, dpiScoped: scoped,
                  // The mouse's own value first: a Cycle Pointer Speed press changes it, not the config.
                  currentDPI: live?.dpi ?? liveScope.flatMap { config.resolvedInt(["dpi"], in: $0) } ?? config.int(["dpi"]),
                  dpiSteps: live?.dpiSteps ?? [])
    }
}
