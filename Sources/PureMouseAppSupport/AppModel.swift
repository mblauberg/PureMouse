import Foundation
import Observation
import PureMouseKit

/// Everything the menu and Settings show, as one object for the panes: the daemon
/// (`DaemonLink`), the config (`ConfigStore`) and select by pressing (`CaptureController`), each
/// over the same `Locations`. No timers and no polling. The app supplies what needs AppKit or
/// UserNotifications: how to show an error, and how to post a low-battery notification.
@MainActor @Observable
public final class AppModel {
    /// Shows a failure to the user: a message and its details.
    public typealias Alert = @MainActor (_ message: String, _ info: String) -> Void
    /// Posts a notification under an identifier, replacing one already posted with it.
    public typealias Announce = @MainActor (_ id: String, _ title: String, _ body: String) -> Void
    /// Takes down delivered notifications by identifier; one no longer there is ignored.
    public typealias Withdraw = @MainActor (_ ids: [String]) -> Void

    @ObservationIgnored let link: DaemonLink
    @ObservationIgnored let store: ConfigStore
    @ObservationIgnored let capture: CaptureController

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored public var statusChanged: () -> Void = {}

    @ObservationIgnored private let alert: Alert
    /// The mice a DPI change moved off a cycled value, to be told to use the configured one once
    /// the file is written: a device key each, or nil for every mouse.
    @ObservationIgnored private var wantedConfiguredDPI: Set<String?> = []
    @ObservationIgnored let defaults: UserDefaults
    static let mouseKey = "SettingsMouse"
    /// The mouse chosen in Settings' pop-up, by device key, remembered per user. nil is All Mice.
    /// Whether it applies is `scope`'s to say.
    public internal(set) var rememberedMouse: String?
    /// The window's undo manager, for the Settings helper; nil for the menu bar app, which keeps no
    /// history (`ConfigStore.keepHistory(on:)`).
    @ObservationIgnored public let undoManager: UndoManager?
    /// Only a model that announces low battery keeps the bands announced (the menu app's).
    @ObservationIgnored private var batteryAlerts: (store: BatteryAlertStore, announce: Announce, withdraw: Withdraw)?

    /// `notifications`: post and take down low-battery notifications (`BatteryAlert`); nil for a
    /// model that never does. `undoManager`: the window's, to undo and redo config changes on; nil
    /// keeps no history.
    public init(locations: Locations = .live, defaults: UserDefaults = .standard, alert: @escaping Alert,
                notifications: (announce: Announce, withdraw: Withdraw)? = nil, undoManager: UndoManager? = nil) {
        self.defaults = defaults
        self.undoManager = undoManager
        rememberedMouse = defaults.string(forKey: Self.mouseKey)
        link = DaemonLink(locations: locations)
        store = ConfigStore(locations: locations)
        if let undoManager { store.keepHistory(on: undoManager) }
        capture = CaptureController(link: link)
        self.alert = alert
        batteryAlerts = notifications.map { (BatteryAlertStore(url: locations.batteryAlerts), $0.announce, $0.withdraw) }
        link.changed = { [weak self, capture] in
            capture.checkDaemon()  // a capture ends with the daemon
            self?.statusChanged()
        }
        store.changed = { [weak self] in
            self?.announceLowBattery()  // the switch may have been turned off
            self?.statusChanged()
        }
        link.statusLoaded = { [weak self] in self?.statusLoaded() }
        capture.pressed = { [weak self] key in self?.selectCapturedMouse(key) }
        link.controlFailed = { alert("PureMouse couldn't be reached.", $0.localizedDescription) }
        store.daemonConfigError = { [link] in link.configError }
        store.flushed = { [weak self] in self?.sendConfiguredDPIIfWanted() }
        // Config first: the status pass reads `notifications.lowBattery`.
        store.reloadConfig()
        link.reloadStatus()
    }

    /// Starts listening for the daemon's doorbell and for config edits.
    public func startWatching() {
        link.startWatching()
        store.startWatching()
    }

    // MARK: Daemon status

    public var status: Status? { link.status }
    public var daemonRunning: Bool { link.daemonRunning }
    public var statusTooNew: Bool { link.statusTooNew }
    public var devices: [Status.Device] { link.devices }
    public var primaryDevice: Status.Device? { link.primaryDevice }
    public var liveDevice: Status.Device? { link.liveDevice }
    public var paused: Bool { link.paused }
    public var accessibilityMissing: Bool { link.accessibilityMissing }
    public var inputMonitoringMissing: Bool { link.inputMonitoringMissing }
    public var logiOptionsRunning: Bool { link.logiOptionsRunning }

    public var hasBluetoothDevice: Bool { link.hasBluetoothDevice }
    public var waitingForInputMonitoring: [Status.WaitingDevice] { link.waitingForInputMonitoring }
    public var inputMonitoringNeeded: Bool { link.inputMonitoringNeeded }

    /// PureMouse is running and sees no mouse at all: none connected, none waiting for Input
    /// Monitoring, and none in the config (a `devices` entry names one that is simply away). Not
    /// while off or paused, when it reports no mice for another reason.
    public var hasNoMouse: Bool {
        daemonRunning && !paused && status != nil && devices.isEmpty && waitingForInputMonitoring.isEmpty
            && config.deviceEntries.isEmpty
    }

    public var lowBattery: Bool {
        guard let battery = liveDevice?.battery, !battery.charging else { return false }
        if let percent = battery.percent { return percent <= 10 }
        return battery.level == .critical
    }

    public func reloadStatus() { link.reloadStatus() }

    public func refreshLiveness() { link.refreshLiveness() }

    private func statusLoaded() {
        if let state = status?.capture { capture.handle(state) }
        announceLowBattery()
    }

    /// Posts a notification when a live mouse's battery falls through 20% or 5% (`BatteryAlert`),
    /// and takes down the ones that stopped being true. Runs on each status the daemon writes and
    /// on each config change, with no timer.
    private func announceLowBattery() {
        guard var batteryAlerts else { return }
        defer { self.batteryAlerts = batteryAlerts }
        let readings = !daemonRunning ? [] : devices.filter(\.online).compactMap { device in
            device.battery.map {
                BatteryAlertStore.Reading(id: device.id, name: device.name, battery: $0, model: device.model, unit: device.unit)
            }
        }
        let outcome = batteryAlerts.store.process(readings, enabled: lowBatteryNotificationsOn)
        if !outcome.remove.isEmpty { batteryAlerts.withdraw(outcome.remove) }
        for alert in outcome.alerts {
            let text = BatteryAlert.message(for: alert.band, device: alert.name, battery: alert.battery)
            batteryAlerts.announce(alert.notificationID, text.title, text.body)
        }
    }

    // MARK: Control

    public func setPaused(_ paused: Bool) {
        if capture.listening { capture.end(notify: false) }
        // A pause ends any capture, so the request clears it as well.
        link.setPaused(paused) { $0.capture = nil }
        statusChanged()
    }

    /// Apply Settings Again: asks the daemon to start a fresh apply where the settings are not applied.
    public func applySettingsAgain() {
        guard daemonRunning else { return }
        link.requestReapply()
    }

    public var captureListening: Bool { capture.listening }

    public var capturedButton: String? {
        get { capture.capturedButton }
        set { capture.capturedButton = newValue }
    }

    /// Starts Find by Pressing on the mouse chosen in the pop-up, or on every mouse for All Mice.
    public func startCapture() { capture.start(device: scope.deviceKey) }

    public func cancelCapture() { capture.cancel() }

    /// How the last Find by Pressing ended, while it is worth saying.
    public var captureOutcome: CaptureController.Outcome? { capture.outcome }

    public func clearCaptureOutcome() { capture.clearOutcome() }

    /// Asks the daemon to reload the config now (it also reloads on its own when the file changes).
    public func reloadDaemonConfig() { link.reloadDaemonConfig() }

    /// See `DaemonLink.askDaemonToRecheck`.
    public func askDaemonToRecheck() { link.askDaemonToRecheck() }

    // MARK: Config

    public var config: ConfigTree { store.config }

    /// Settings' "Low battery" notifications switch (on unless turned off).
    public var lowBatteryNotificationsOn: Bool { config.bool(["notifications", "lowBattery"]) ?? true }
    public var writeError: String? { store.writeError }
    public var configError: String? { store.configError }
    public var readOnly: Bool { store.readOnly }
    public var canRestoreLastWorking: Bool { store.canRestoreLastWorking }

    public func reloadConfig() { store.reloadConfig() }

    public func set(_ value: Any?, at path: [String], debounce: Bool = false) { store.set(value, at: path, debounce: debounce) }

    public func update(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) { store.update(debounce: debounce, change) }

    /// Sets `path` (relative to the scope) in `target`, or removes it with nil: for a mouse, only
    /// under `devices.<key>`, which a first write creates with the mouse's `name`.
    public func set(_ value: Any?, at path: [String], in target: ScopeTarget, debounce: Bool = false) {
        update(debounce: debounce, in: target) { $0.set(value, at: path, in: target.scope) }
    }

    /// An edit made in `target`'s scope. A device entry it leaves holding only its name goes, and
    /// one it creates is given the name.
    public func update(debounce: Bool = false, in target: ScopeTarget, _ change: (inout ConfigTree) -> Void) {
        store.update(debounce: debounce) {
            $0.entryName = target.name
            change(&$0)
            $0.settleEntry(for: target.scope, name: target.name)
            $0.entryName = nil
        }
    }

    public func flush() { store.flush() }

    /// Runs a login or lifecycle command, then `success`; if it fails, an alert. A trailing
    /// closure is `success`: this form has no other closure it could bind to.
    public func perform(_ command: Lifecycle.Command, then success: @escaping @MainActor () -> Void = {}) {
        perform(command, then: success, otherwise: {})
    }

    /// The same, running `failure` before the alert. Neither closure has a default, so a call
    /// with one trailing closure never reaches this form and can never bind it to `failure`.
    public func perform(_ command: Lifecycle.Command, then success: @escaping @MainActor () -> Void,
                        otherwise failure: @escaping @MainActor () -> Void) {
        Lifecycle.run(command, daemon: locations.daemon) { [alert] result in
            switch result {
            case .success: success()
            case .failure(let error):
                failure()
                alert("PureMouse couldn't do that.", error.description)
            }
        }
    }

    public func resetAll() { store.resetAll() }

    public func restoreLastWorking() { store.restoreLastWorking() }

    public func createConfigIfMissing() { store.createIfMissing() }

    /// Export Settings…: a copy of the config at `url`. Returns why it failed, or nil.
    public func exportSettings(to url: URL) -> String? { store.exportSettings(to: url) }

    /// Import Settings…, once confirmed: replaces the whole config with a file `ConfigTransfer.read`
    /// accepted, keeping the previous one as `backupName`. Returns why it failed, or nil.
    public func importSettings(_ candidate: ConfigTransfer.Candidate) -> String? { store.importSettings(candidate) }

    /// The file Reset All Settings and Restore Last Working keep the previous config in.
    public var backupName: String { store.backupName }

    public var locations: Locations { store.locations }

    /// Sets the saved DPI and puts every mouse on it. A mouse on a DPI chosen by Cycle Pointer
    /// Speed keeps it through a reload that leaves `dpi` alone, and choosing the value already
    /// saved changes nothing on disk, so once the file is written the daemon is also asked to
    /// drop the cycled one.
    ///
    /// In a mouse's scope (`target`), the DPI is written under that mouse only, and only that mouse
    /// is told. The status menu passes a mouse's scope when it sets a speed for one mouse (two or
    /// more mice, or a mouse whose own entry sets `dpi` or `dpiPresets`: `setPointerSpeed`), and
    /// none otherwise, which sets the top level.
    public func setDPI(_ dpi: Int, debounce: Bool = false, in target: ScopeTarget = .allMice) {
        guard !readOnly else { return }
        let key = target.scope.deviceKey
        let moved = devices.contains { $0.dpi != nil && $0.dpi != dpi && (key == nil || $0.deviceKey == key) }
        if moved { wantedConfiguredDPI.insert(key) }
        set(dpi, at: ["dpi"], in: target, debounce: debounce)
        if !store.hasPendingChanges { flush() }  // nothing to write: ask now
    }

    private func sendConfiguredDPIIfWanted() {
        guard !wantedConfiguredDPI.isEmpty else { return }
        let wanted = wantedConfiguredDPI
        wantedConfiguredDPI = []
        guard daemonRunning else { return }
        // One mouse is asked by its key; several, or all, by asking every mouse.
        link.requestConfiguredDPI(device: wanted.count == 1 ? wanted.first! : nil)
    }
}
