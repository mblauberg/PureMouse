import AppKit
import Observation
import PureMouseKit
import notify

/// Everything the menu and Settings show: the daemon's status (pushed by its doorbell) and the
/// config tree (re-read when its directory changes). No timers and no polling.
@MainActor @Observable
final class AppModel {
    // MARK: Daemon status

    private(set) var status: Status?
    /// `status.running` and its process exists.
    private(set) var daemonRunning = false
    /// The daemon writes a newer status schema than this app understands.
    private(set) var statusTooNew = false

    // MARK: Config

    private(set) var config = ConfigTree()
    /// Why the file on disk cannot be used (unreadable, not JSON, or rejected by the decoder).
    private(set) var configProblem: String?
    /// Why the last change could not be saved.
    private(set) var writeError: String?

    // MARK: Select by pressing

    private(set) var captureListening = false
    /// The config key of the control just pressed; the Buttons pane highlights it and opens its picker.
    var capturedButton: String?

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored var statusChanged: () -> Void = {}

    @ObservationIgnored private var diskBytes: Data?
    @ObservationIgnored private var lastGood: Data?
    @ObservationIgnored private var pendingWrite: DispatchWorkItem?
    /// Edits made here and not yet saved, as the keys they set. Saving replays them onto the file
    /// as it is then, so a hand edit made meanwhile is kept.
    @ObservationIgnored private var pendingChanges: [ConfigTree.Change] = []
    @ObservationIgnored private var captureToken = 0
    @ObservationIgnored private var captureTimeout: DispatchWorkItem?
    @ObservationIgnored private var requestedPaused: Bool?
    @ObservationIgnored private var wantsConfiguredDPI = false
    @ObservationIgnored private var exitWatch: DispatchSourceProcess?
    @ObservationIgnored private var watchedPID: Int32 = 0
    @ObservationIgnored private var directoryWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var statusToken: Int32 = -1

    init() {
        reloadStatus()
        reloadConfig()
    }

    /// Starts listening for the daemon's doorbell and for config edits.
    func startWatching() {
        notify_register_dispatch(Companion.statusNotification, &statusToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadStatus() }
        }
        watchConfigDirectory()
    }

    // MARK: Derived state

    var devices: [Status.Device] { status?.devices ?? [] }

    /// The mouse the menu and the Pointer pane describe: the first one online, else the last seen.
    var primaryDevice: Status.Device? { Self.primary(of: devices) }

    /// A device that is connected now and answering (live values come from it).
    var liveDevice: Status.Device? { daemonRunning ? Self.live(of: devices) : nil }

    nonisolated static func primary(of devices: [Status.Device]) -> Status.Device? {
        live(of: devices) ?? devices.first
    }

    nonisolated static func live(of devices: [Status.Device]) -> Status.Device? { devices.first(where: \.online) }

    var paused: Bool { daemonRunning && (requestedPaused ?? status?.paused ?? false) }

    var accessibilityMissing: Bool { daemonRunning && status?.permissions.accessibility == false }

    var inputMonitoringMissing: Bool { daemonRunning && status?.permissions.inputMonitoring == false }

    var logiOptionsRunning: Bool { daemonRunning && status?.logiOptionsRunning == true }

    /// The daemon's or this app's complaint about the config file.
    var configError: String? {
        configProblem ?? (daemonRunning ? status?.config.error : nil)
    }

    /// Panes are read-only while the config file has an error: editing would build on a file
    /// the daemon is not using.
    var readOnly: Bool { configError != nil }

    var hasBluetoothDevice: Bool { devices.contains { $0.connection == .bluetooth } }

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

    // MARK: Status

    func reloadStatus() {
        let url = Companion.statusURL
        if let data = try? Data(contentsOf: url) {
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
        if let capture = status?.capture { handleCapture(capture) }
    }

    /// Re-checks that the daemon's process exists (`running` alone survives a crash).
    func refreshLiveness() {
        let pid = status?.pid ?? 0
        assign(\.daemonRunning, status?.running == true && pid > 0 && kill(pid, 0) == 0)
        if requestedPaused != nil, status?.paused == requestedPaused || !daemonRunning || pid != watchedPID {
            requestedPaused = nil
        }
        watchExit(of: daemonRunning ? pid : 0)
        if !daemonRunning, captureListening { endCapture() }
        statusChanged()
    }

    /// Sets an observed property only when the value differs, so an unchanged status (the daemon
    /// rings for every capture step and battery reading) invalidates no views.
    private func assign<Value: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
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

    func setPaused(_ paused: Bool) {
        let previous = requestedPaused
        requestedPaused = paused
        if captureListening { endCapture(notify: false) }
        // The daemon never heard it: show what it is still doing.
        if !writeControl(capture: nil) { requestedPaused = previous }
        statusChanged()
    }

    func startCapture() {
        guard daemonRunning, !paused else { return }
        captureToken = Int.random(in: 1...Int(Int32.max))
        captureListening = true
        capturedButton = nil
        guard writeControl(capture: Control.Capture(token: captureToken)) else {
            captureListening = false
            return
        }
        // The daemon reports timedOut after 10 s; this covers a daemon that never answers.
        let timeout = DispatchWorkItem { [weak self] in self?.cancelCapture() }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 11, execute: timeout)
    }

    func cancelCapture() {
        guard captureListening else { return }
        endCapture()
    }

    private func endCapture(notify: Bool = true) {
        captureListening = false
        captureTimeout?.cancel()
        captureTimeout = nil
        if notify, daemonRunning { writeControl(capture: nil) }
    }

    private func handleCapture(_ capture: Status.Capture) {
        guard captureListening, capture.token == captureToken else { return }
        switch capture.state {
        case .listening:
            break
        case .pressed:
            captureListening = false
            captureTimeout?.cancel()
            capturedButton = capture.cid.map(NamedButton.config(cid:))
        case .timedOut, .cancelled:
            captureListening = false
            captureTimeout?.cancel()
        }
    }

    /// Writes the control file and rings the daemon; false (after saying why) if it could not.
    @discardableResult
    private func writeControl(capture: Control.Capture?, useConfiguredDPI: Int? = nil) -> Bool {
        let control = Control(paused: requestedPaused ?? status?.paused ?? false, capture: capture,
                              useConfiguredDPI: useConfiguredDPI)
        do {
            try Companion.write(control, to: Companion.controlURL)
            notify_post(Companion.controlNotification)
            return true
        } catch {
            Alerts.show("PureMouse could not be reached", error.localizedDescription)
            return false
        }
    }

    /// Asks the daemon to reload the config now (it also reloads on its own when the file changes).
    func reloadDaemonConfig() {
        guard daemonRunning, let pid = status?.pid else { return }
        kill(pid, SIGHUP)
    }

    // MARK: Config

    /// Re-reads the config file. Our own writes come back as no-ops (same bytes).
    func reloadConfig() {
        let url = Paths.config
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Deleted while a change of ours waits: save it as a new file now.
            if !pendingChanges.isEmpty {
                if diskBytes != nil { flush() }
                return
            }
            // No file: the daemon runs with every default.
            if diskBytes != nil || configProblem != nil || !config.root.isEmpty {
                config = ConfigTree()
                configProblem = nil
                diskBytes = nil
                lastGood = Data("{}\n".utf8)
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            configProblem = "PureMouse cannot read \(Format.tildePath(url.path))."
            return
        }
        guard data != diskBytes else { return }
        // Edited by hand while a change of ours waits: save ours on top of the new file now.
        if !pendingChanges.isEmpty {
            flush()
            return
        }
        diskBytes = data
        if let tree = try? ConfigTree(data: data) { config = tree }
        do {
            try ConfigCheck.validate(data)
            configProblem = nil
            lastGood = data
        } catch {
            configProblem = ConfigCheck.message(for: error)
        }
        writeError = nil
        statusChanged()
    }

    /// Sets or (with nil) removes one key. Sliders pass `debounce` so dragging writes once it rests.
    func set(_ value: Any?, at path: [String], debounce: Bool = false) {
        update(debounce: debounce) { $0.set(value, at: path) }
    }

    func update(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) {
        guard !readOnly else { return }
        var tree = config
        change(&tree)
        pendingChanges += config.changes(to: tree)
        config = tree
        if debounce {
            pendingWrite?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            pendingWrite = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            flush()
        }
    }

    /// Saves pending edits now (also when Settings closes and before quitting). Writes nothing
    /// when there are none, and never builds on a file that does not load.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        defer { sendConfiguredDPIIfWanted() }
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges = []
        do {
            let saved = try ConfigFile(url: Paths.config).save(changes)
            config = saved.tree
            diskBytes = saved.data
            if let data = saved.data { lastGood = data }
            writeError = nil
            if directoryWatch == nil { watchConfigDirectory() }
        } catch {
            // Show the file as it is now, then say why the change did not land.
            diskBytes = nil
            reloadConfig()
            writeError = describeSave(error)
        }
    }

    /// Sets the saved DPI and puts every mouse on it. A mouse on a DPI chosen by Cycle Pointer
    /// Speed keeps it through a reload that leaves `dpi` alone, and choosing the value already
    /// saved changes nothing on disk, so once the file is written the daemon is also asked to
    /// drop the cycled one.
    func setDPI(_ dpi: Int, debounce: Bool = false) {
        guard !readOnly else { return }
        if devices.contains(where: { $0.dpi != nil && $0.dpi != dpi }) { wantsConfiguredDPI = true }
        set(dpi, at: ["dpi"], debounce: debounce)
        if pendingChanges.isEmpty { flush() }  // nothing to write: ask now
    }

    private func sendConfiguredDPIIfWanted() {
        guard wantsConfiguredDPI else { return }
        wantsConfiguredDPI = false
        guard daemonRunning else { return }
        writeControl(capture: captureListening ? Control.Capture(token: captureToken) : nil,
                     useConfiguredDPI: Int.random(in: 1...Int(Int32.max)))
    }

    /// Replaces the whole file with `{}` (every setting back to the mouse's own).
    func resetAll() {
        pendingWrite?.cancel()
        pendingChanges = []
        config = ConfigTree()
        configProblem = nil
        write(config.data())
    }

    /// Puts back the last config that loaded, after a hand edit broke it.
    var canRestoreLastWorking: Bool { lastGood != nil && configProblem != nil }

    func restoreLastWorking() {
        guard let lastGood, let tree = try? ConfigTree(data: lastGood) else { return }
        pendingWrite?.cancel()
        pendingChanges = []
        config = tree
        configProblem = nil
        write(lastGood)
    }

    private func write(_ data: Data) {
        do {
            try ConfigFile(url: Paths.config).write(data)
            diskBytes = data
            lastGood = data
            writeError = nil
            if directoryWatch == nil { watchConfigDirectory() }
        } catch {
            writeError = describeSave(error)
        }
    }

    private func describeSave(_ error: Error) -> String {
        switch error {
        case ConfigFile.SaveError.fileHasError:
            "The config file changed and has an error, so this change was not saved."
        case ConfigFile.SaveError.rejected(let reason):
            ConfigCheck.message(for: reason)
        case ConfigFile.SaveError.writeFailed(let reason):
            "PureMouse could not save \(Format.tildePath(Paths.config.path)): \(reason.localizedDescription)"
        default:
            error.localizedDescription
        }
    }

    /// The file is replaced atomically, so its own descriptor goes stale: watch the directory.
    private func watchConfigDirectory() {
        directoryWatch?.cancel()
        directoryWatch = nil
        let directory = Paths.config.resolvingSymlinksInPath().deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.directoryWatch else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.watchConfigDirectory()
                }
                self.reloadConfig()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatch = source
    }
}
