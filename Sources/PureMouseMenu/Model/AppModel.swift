import AppKit
import Observation
import PureMouseAppSupport
import PureMouseKit

/// Everything the menu and Settings show, as one object for the panes: the daemon
/// (`DaemonLink`), the config (`ConfigStore`) and select by pressing (`CaptureController`), each
/// over the same `Locations`. No timers and no polling.
@MainActor @Observable
final class AppModel {
    @ObservationIgnored let link: DaemonLink
    @ObservationIgnored let store: ConfigStore
    @ObservationIgnored let capture: CaptureController

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored var statusChanged: () -> Void = {}

    @ObservationIgnored private var wantsConfiguredDPI = false
    @ObservationIgnored private var batteryAlerts: BatteryAlertStore

    init(locations: Locations = .live) {
        link = DaemonLink(locations: locations)
        store = ConfigStore(locations: locations)
        capture = CaptureController(link: link)
        batteryAlerts = BatteryAlertStore(url: locations.batteryAlerts)
        link.changed = { [weak self] in self?.statusChanged() }
        store.changed = { [weak self] in self?.statusChanged() }
        link.livenessChecked = { [capture] in capture.checkDaemon() }
        link.statusLoaded = { [weak self] in self?.statusLoaded() }
        link.controlFailed = { Alerts.show("PureMouse could not be reached", $0.localizedDescription) }
        store.daemonConfigError = { [link] in link.configError }
        store.flushed = { [weak self] in self?.sendConfiguredDPIIfWanted() }
        // Config first: the status pass reads `notifications.lowBattery`.
        store.reloadConfig()
        link.reloadStatus()
    }

    /// Starts listening for the daemon's doorbell and for config edits.
    func startWatching() {
        link.startWatching()
        store.startWatching()
    }

    // MARK: Daemon status

    var status: Status? { link.status }
    var daemonRunning: Bool { link.daemonRunning }
    var statusTooNew: Bool { link.statusTooNew }
    var devices: [Status.Device] { link.devices }
    var primaryDevice: Status.Device? { link.primaryDevice }
    var liveDevice: Status.Device? { link.liveDevice }
    var paused: Bool { link.paused }
    var accessibilityMissing: Bool { link.accessibilityMissing }
    var inputMonitoringMissing: Bool { link.inputMonitoringMissing }
    var logiOptionsRunning: Bool { link.logiOptionsRunning }
    var hasBluetoothDevice: Bool { link.hasBluetoothDevice }

    /// Something needs the user: a missing permission, a config error, Options+, or a newer daemon.
    var needsAttention: Bool {
        statusTooNew || (daemonRunning && (accessibilityMissing || (inputMonitoringMissing && hasBluetoothDevice)
            || logiOptionsRunning || configError != nil))
    }

    var lowBattery: Bool {
        guard let battery = liveDevice?.battery, !battery.charging else { return false }
        if let percent = battery.percent { return percent <= 10 }
        return battery.level == .critical
    }

    func reloadStatus() { link.reloadStatus() }

    func refreshLiveness() { link.refreshLiveness() }

    private func statusLoaded() {
        if let state = status?.capture { capture.handle(state) }
        announceLowBattery()
    }

    /// Posts a notification when a live mouse's battery falls through 20% or 5% (`BatteryAlert`).
    /// Runs on each status the daemon writes, with no timer.
    private func announceLowBattery() {
        let readings = !daemonRunning ? [] : devices.filter(\.online).compactMap { device in
            device.battery.map { BatteryAlertStore.Reading(id: device.id, name: device.name, battery: $0) }
        }
        let wanted = config.bool(["notifications", "lowBattery"]) ?? true
        for alert in batteryAlerts.process(readings, enabled: wanted) {
            let text = BatteryAlert.message(for: alert.band, device: alert.name, battery: alert.battery)
            Notifier.post(id: "battery.\(alert.id).\(alert.band.rawValue)", title: text.title, body: text.body)
        }
    }

    // MARK: Control

    func setPaused(_ paused: Bool) {
        if capture.listening { capture.end(notify: false) }
        link.setPaused(paused)
        statusChanged()
    }

    var captureListening: Bool { capture.listening }

    var capturedButton: String? {
        get { capture.capturedButton }
        set { capture.capturedButton = newValue }
    }

    func startCapture() { capture.start() }

    func cancelCapture() { capture.cancel() }

    /// Asks the daemon to reload the config now (it also reloads on its own when the file changes).
    func reloadDaemonConfig() { link.reloadDaemonConfig() }

    // MARK: Config

    var config: ConfigTree { store.config }
    var writeError: String? { store.writeError }
    var configError: String? { store.configError }
    var readOnly: Bool { store.readOnly }
    var canRestoreLastWorking: Bool { store.canRestoreLastWorking }

    func reloadConfig() { store.reloadConfig() }

    func set(_ value: Any?, at path: [String], debounce: Bool = false) { store.set(value, at: path, debounce: debounce) }

    func update(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) { store.update(debounce: debounce, change) }

    func flush() { store.flush() }

    func resetAll() { store.resetAll() }

    func restoreLastWorking() { store.restoreLastWorking() }

    /// Sets the saved DPI and puts every mouse on it. A mouse on a DPI chosen by Cycle Pointer
    /// Speed keeps it through a reload that leaves `dpi` alone, and choosing the value already
    /// saved changes nothing on disk, so once the file is written the daemon is also asked to
    /// drop the cycled one.
    func setDPI(_ dpi: Int, debounce: Bool = false) {
        guard !readOnly else { return }
        if devices.contains(where: { $0.dpi != nil && $0.dpi != dpi }) { wantsConfiguredDPI = true }
        set(dpi, at: ["dpi"], debounce: debounce)
        if !store.hasPendingChanges { flush() }  // nothing to write: ask now
    }

    private func sendConfiguredDPIIfWanted() {
        guard wantsConfiguredDPI else { return }
        wantsConfiguredDPI = false
        guard daemonRunning else { return }
        link.requestConfiguredDPI()
    }
}
