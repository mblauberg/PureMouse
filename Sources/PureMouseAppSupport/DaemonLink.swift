import Foundation
import Observation
import PureMouseKit
import notify

/// The daemon as the menu sees it: its status (pushed by its doorbell), whether its process
/// lives, and the control file this side writes (docs/companion.md). No timers and no polling: a
/// process source reports the daemon's exit.
@MainActor @Observable
public final class DaemonLink {
    public private(set) var status: Status?
    /// `status.running` and its process exists.
    public private(set) var daemonRunning = false
    /// The daemon writes a newer status schema than this app understands.
    public private(set) var statusTooNew = false

    /// The select-by-pressing request this process has open (`CaptureController`). The next
    /// control write sends it; writes after that keep the file's value, so a pause or DPI request
    /// from here cannot cancel a capture another process started.
    @ObservationIgnored public var capture: Control.Capture? {
        didSet { captureChanged = true }
    }
    @ObservationIgnored private var captureChanged = false

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored public var changed: @MainActor () -> Void = {}
    /// Called after each liveness check, before `changed` (a capture ends with the daemon).
    @ObservationIgnored public var livenessChecked: @MainActor () -> Void = {}
    /// Called after each status file is read and checked.
    @ObservationIgnored public var statusLoaded: @MainActor () -> Void = {}
    /// Called when the control file cannot be written, before the write reports false.
    @ObservationIgnored public var controlFailed: @MainActor (Error) -> Void = { _ in }

    /// The `control.json` fields this process owns; a write changes only these and keeps the
    /// rest as the file has them (another process may own them).
    public struct ControlFields: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let paused = ControlFields(rawValue: 1)
        public static let capture = ControlFields(rawValue: 2)
        public static let useConfiguredDPI = ControlFields(rawValue: 4)
        /// The status menu: pause and resume, and the DPI it sets.
        public static let menu: ControlFields = [.paused, .useConfiguredDPI]
        /// Settings: select by pressing, and the DPI it sets.
        public static let settings: ControlFields = [.capture, .useConfiguredDPI]
        public static let all: ControlFields = [.paused, .capture, .useConfiguredDPI]
    }

    public let owns: ControlFields

    @ObservationIgnored private let locations: Locations
    @ObservationIgnored private let isAlive: (Int32) -> Bool
    @ObservationIgnored private let newToken: () -> Int
    @ObservationIgnored private let ring: () -> Void
    @ObservationIgnored private var requestedPaused: Bool?
    /// The last `Control.useConfiguredDPI` this process sent. Later writes keep the file's token
    /// (this one, or a newer one from another writer), so a pause or capture cannot erase it
    /// before the daemon reads it; the daemon acts once per token.
    @ObservationIgnored public private(set) var dpiToken: Int?
    @ObservationIgnored private var exitWatch: DispatchSourceProcess?
    @ObservationIgnored private var watchedPID: Int32 = 0
    @ObservationIgnored private var statusToken: Int32 = -1

    /// - Parameters:
    ///   - isAlive: whether a process exists (`kill(pid, 0)`).
    ///   - newToken: a fresh request token.
    ///   - ring: the doorbell after a control write.
    ///   - owns: the `control.json` fields this process writes.
    public init(locations: Locations, owns: ControlFields = .all,
                isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 },
                newToken: @escaping () -> Int = { Int.random(in: 1...Int(Int32.max)) },
                ring: @escaping () -> Void = { notify_post(Companion.controlNotification) }) {
        self.locations = locations
        self.owns = owns
        self.isAlive = isAlive
        self.newToken = newToken
        self.ring = ring
    }

    /// Starts listening for the daemon's doorbell.
    public func startWatching() {
        notify_register_dispatch(Companion.statusNotification, &statusToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadStatus() }
        }
    }

    // MARK: Derived state

    public var devices: [Status.Device] { status?.devices ?? [] }

    /// The mouse the menu and the Pointer pane describe: the first one online, else the last seen.
    public var primaryDevice: Status.Device? { Status.Device.primary(of: devices) }

    /// A device that is connected now and answering (live values come from it).
    public var liveDevice: Status.Device? { daemonRunning ? Status.Device.live(of: devices) : nil }

    public var paused: Bool { daemonRunning && (requestedPaused ?? status?.paused ?? false) }

    public var accessibilityMissing: Bool { daemonRunning && status?.permissions.accessibility == false }

    public var inputMonitoringMissing: Bool { daemonRunning && status?.permissions.inputMonitoring == false }

    public var logiOptionsRunning: Bool { daemonRunning && status?.logiOptionsRunning == true }

    public var hasBluetoothDevice: Bool { devices.contains { $0.connection == .bluetooth } }

    /// The daemon's complaint about the config file, while it runs.
    public var configError: String? { daemonRunning ? status?.config.error : nil }

    // MARK: Status

    public func reloadStatus() {
        if let data = try? Data(contentsOf: locations.status) {
            if let decoded = try? Companion.decoder.decode(Status.self, from: data) {
                assign(\.statusTooNew, decoded.schema > Status.currentSchema)
                assign(\.status, decoded)
            } else {
                let schema = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schema"] as? Int
                assign(\.statusTooNew, (schema ?? 0) > Status.currentSchema)
                assign(\.status, nil)
            }
        } else {
            assign(\.status, nil)
            assign(\.statusTooNew, false)
        }
        refreshLiveness()
        statusLoaded()
    }

    /// Re-checks that the daemon's process exists (`running` alone survives a crash).
    public func refreshLiveness() {
        let pid = status?.pid ?? 0
        assign(\.daemonRunning, status?.running == true && pid > 0 && isAlive(pid))
        if requestedPaused != nil, status?.paused == requestedPaused || !daemonRunning || pid != watchedPID {
            requestedPaused = nil
        }
        watchExit(of: daemonRunning ? pid : 0)
        livenessChecked()
        changed()
    }

    /// Sets an observed property only when the value differs, so an unchanged status (the daemon
    /// rings for every capture step and battery reading) invalidates no views.
    private func assign<Value: Equatable>(_ key: ReferenceWritableKeyPath<DaemonLink, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// A process source tells us the moment the daemon dies, so a crash (which cannot write a
    /// final status) still turns the icon off. It costs nothing while the daemon lives.
    private func watchExit(of pid: Int32) {
        guard pid != watchedPID else { return }
        exitWatch?.cancel()
        exitWatch = nil
        watchedPID = pid
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshLiveness() }
        }
        source.resume()
        exitWatch = source
    }

    // MARK: Control

    /// Asks the daemon to pause or resume; false if the request could not be written, in which
    /// case the menu goes on showing what the daemon is still doing.
    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        let previous = requestedPaused
        requestedPaused = paused
        guard writeControl() else {
            requestedPaused = previous
            return false
        }
        return true
    }

    /// Asks the daemon to drop a DPI chosen by Cycle Pointer Speed, with a new token.
    @discardableResult
    public func requestConfiguredDPI() -> Bool {
        let token = newToken()
        guard write(newDPIToken: token) else { return false }
        dpiToken = token
        return true
    }

    /// Writes this process's fields of the control file and rings the daemon; false (after
    /// `controlFailed`) if it could not.
    @discardableResult
    public func writeControl() -> Bool { write(newDPIToken: nil) }

    /// One read-merge-replace of `control.json` under `control.json.lock`: the owned fields come
    /// from here (`paused` only while a request is pending, `capture` only when this process
    /// changed it, `useConfiguredDPI` only when new), the rest stay as the file has them. With no
    /// file, `paused` follows the daemon's status.
    private func write(newDPIToken: Int?) -> Bool {
        let url = locations.control
        do {
            try FileLock.withLock(FileLock.url(for: url)) {
                var control = Companion.read(Control.self, from: url) ?? Control(paused: status?.paused ?? false)
                if owns.contains(.paused), let requestedPaused { control.paused = requestedPaused }
                if owns.contains(.capture), captureChanged { control.capture = capture }
                if owns.contains(.useConfiguredDPI), let newDPIToken { control.useConfiguredDPI = newDPIToken }
                try Companion.write(control, to: url)
            }
            captureChanged = false
            ring()
            return true
        } catch {
            controlFailed(error)
            return false
        }
    }

    /// Asks the daemon to reload the config now (it also reloads on its own when the file changes).
    public func reloadDaemonConfig() {
        guard daemonRunning, let pid = status?.pid else { return }
        kill(pid, SIGHUP)
    }
}
