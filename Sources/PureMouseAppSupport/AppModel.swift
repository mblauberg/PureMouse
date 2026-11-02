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

    @ObservationIgnored let link: DaemonLink
    @ObservationIgnored let store: ConfigStore
    @ObservationIgnored let capture: CaptureController

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored public var statusChanged: () -> Void = {}

    @ObservationIgnored private let alert: Alert
    @ObservationIgnored private var wantsConfiguredDPI = false
    /// Only a model that announces low battery keeps the bands announced (the menu app's).
    @ObservationIgnored private var batteryAlerts: (store: BatteryAlertStore, announce: Announce)?

    /// `announce`: post low-battery notifications (`BatteryAlert`); nil for a model that never does.
    public init(locations: Locations = .live, alert: @escaping Alert, announce: Announce? = nil) {
        link = DaemonLink(locations: locations)
        store = ConfigStore(locations: locations)
        capture = CaptureController(link: link)
        self.alert = alert
        batteryAlerts = announce.map { (BatteryAlertStore(url: locations.batteryAlerts), $0) }
        link.changed = { [weak self, capture] in
            capture.checkDaemon()  // a capture ends with the daemon
            self?.statusChanged()
        }
        store.changed = { [weak self] in self?.statusChanged() }
        link.statusLoaded = { [weak self] in self?.statusLoaded() }
        link.controlFailed = { alert("PureMouse could not be reached", $0.localizedDescription) }
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

    /// Posts a notification when a live mouse's battery falls through 20% or 5% (`BatteryAlert`).
    /// Runs on each status the daemon writes, with no timer.
    private func announceLowBattery() {
        guard var batteryAlerts else { return }
        defer { self.batteryAlerts = batteryAlerts }
        let readings = !daemonRunning ? [] : devices.filter(\.online).compactMap { device in
            device.battery.map { BatteryAlertStore.Reading(id: device.id, name: device.name, battery: $0) }
        }
        let wanted = config.bool(["notifications", "lowBattery"]) ?? true
        for alert in batteryAlerts.store.process(readings, enabled: wanted) {
            let text = BatteryAlert.message(for: alert.band, device: alert.name, battery: alert.battery)
            batteryAlerts.announce( "battery.\(alert.id).\(alert.band.rawValue)", text.title, text.body)
        }
    }

    // MARK: Control

    public func setPaused(_ paused: Bool) {
        if capture.listening { capture.end(notify: false) }
        // A pause ends any capture, so the request clears it as well.
        link.setPaused(paused) { $0.capture = nil }
        statusChanged()
    }

    public var captureListening: Bool { capture.listening }

    public var capturedButton: String? {
        get { capture.capturedButton }
        set { capture.capturedButton = newValue }
    }

    public func startCapture() { capture.start() }

    public func cancelCapture() { capture.cancel() }

    /// Asks the daemon to reload the config now (it also reloads on its own when the file changes).
    public func reloadDaemonConfig() { link.reloadDaemonConfig() }

    // MARK: Config

    public var config: ConfigTree { store.config }
    public var writeError: String? { store.writeError }
    public var configError: String? { store.configError }
    public var readOnly: Bool { store.readOnly }
    public var canRestoreLastWorking: Bool { store.canRestoreLastWorking }

    public func reloadConfig() { store.reloadConfig() }

    public func set(_ value: Any?, at path: [String], debounce: Bool = false) { store.set(value, at: path, debounce: debounce) }

    public func update(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) { store.update(debounce: debounce, change) }

    public func flush() { store.flush() }

    /// Runs a login or lifecycle command and shows an alert if it fails.
    public func perform(_ command: Lifecycle.Command, then success: @escaping @MainActor () -> Void = {}) {
        Lifecycle.run(command, daemon: locations.daemon) { [alert] result in
            switch result {
            case .success: success()
            case .failure(let error): alert("PureMouse could not do that", error.description)
            }
        }
    }

    public func resetAll() { store.resetAll() }

    public func restoreLastWorking() { store.restoreLastWorking() }

    public func createConfigIfMissing() { store.createIfMissing() }

    /// The file Reset All Settings and Restore Last Working keep the previous config in.
    public var backupName: String { store.backupName }

    public var locations: Locations { store.locations }

    /// Sets the saved DPI and puts every mouse on it. A mouse on a DPI chosen by Cycle Pointer
    /// Speed keeps it through a reload that leaves `dpi` alone, and choosing the value already
    /// saved changes nothing on disk, so once the file is written the daemon is also asked to
    /// drop the cycled one.
    public func setDPI(_ dpi: Int, debounce: Bool = false) {
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
