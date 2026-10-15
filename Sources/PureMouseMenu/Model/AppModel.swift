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
    var primaryDevice: Status.Device? { devices.first(where: \.online) ?? devices.first }

    /// A device that is connected now and answering (live values come from it).
    var liveDevice: Status.Device? { daemonRunning ? devices.first(where: \.online) : nil }

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
                statusTooNew = decoded.schema > Status.currentSchema
                status = decoded
            } else {
                let schema = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schema"] as? Int
                statusTooNew = (schema ?? 0) > Status.currentSchema
                status = nil
            }
        } else {
            status = nil
            statusTooNew = false
        }
        refreshLiveness()
        if let capture = status?.capture { handleCapture(capture) }
    }

    /// Re-checks that the daemon's process exists (`running` alone survives a crash).
    func refreshLiveness() {
        let pid = status?.pid ?? 0
        daemonRunning = status?.running == true && pid > 0 && kill(pid, 0) == 0
        if requestedPaused != nil, status?.paused == requestedPaused || !daemonRunning || pid != watchedPID {
            requestedPaused = nil
        }
        watchExit(of: daemonRunning ? pid : 0)
        if !daemonRunning, captureListening { endCapture() }
        statusChanged()
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
        requestedPaused = paused
        if captureListening { endCapture(notify: false) }
        writeControl(capture: nil)
        statusChanged()
    }

    func startCapture() {
        guard daemonRunning, !paused else { return }
        captureToken = Int.random(in: 1...Int(Int32.max))
        captureListening = true
        capturedButton = nil
        writeControl(capture: Control.Capture(token: captureToken))
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

    private func writeControl(capture: Control.Capture?) {
        let control = Control(paused: requestedPaused ?? status?.paused ?? false, capture: capture)
        do {
            try Companion.write(control, to: Companion.controlURL)
            notify_post(Companion.controlNotification)
        } catch {
            Alerts.show("PureMouse could not be reached", error.localizedDescription)
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
        do {
            let tree = try ConfigTree(data: data)
            config = tree
            try ConfigCheck.validate(data)
            configProblem = nil
            lastGood = data
        } catch {
            configProblem = Self.describe(error)
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
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges = []
        // Re-read the file, so a hand edit made since it was loaded survives our change.
        let url = Paths.config
        let current: Data?
        let fresh: ConfigTree
        do {
            current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            fresh = try current.map { try ConfigTree(data: $0) } ?? ConfigTree()
            if let current { try ConfigCheck.validate(current) }
        } catch {
            diskBytes = nil
            reloadConfig()
            writeError = "The config file changed and has an error, so this change was not saved."
            return
        }
        var tree = fresh
        tree.apply(changes)
        let data = tree.data()
        guard data != current else {
            diskBytes = current
            config = tree
            return
        }
        do {
            try ConfigCheck.validate(data)
        } catch {
            writeError = Self.describe(error)
            diskBytes = current
            config = fresh
            return
        }
        config = tree
        write(data)
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
        // Follow a symlinked config (dotfiles) and replace its target, not the link.
        let url = Paths.config.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            diskBytes = data
            lastGood = data
            writeError = nil
            if directoryWatch == nil { watchConfigDirectory() }
        } catch {
            writeError = "PureMouse could not save \(Format.tildePath(url.path)): \(error.localizedDescription)"
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

    /// The decoder's error as one sentence that names the field.
    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case DecodingError.dataCorrupted(let context):
            if let underlying = context.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return "Not valid JSON: \(detail)"
            }
            return context.debugDescription
        case DecodingError.typeMismatch(let type, let context):
            return "\(path(context)) should be \(Self.typeName(type))."
        case DecodingError.valueNotFound(_, let context):
            return "\(path(context)) is missing a value."
        case DecodingError.keyNotFound(let key, let context):
            return "\(([path(context)] + [key.stringValue]).filter { !$0.isEmpty }.joined(separator: ".")) is missing."
        case let error as NSError where error.userInfo[NSDebugDescriptionErrorKey] != nil:
            return "Not valid JSON: \(error.userInfo[NSDebugDescriptionErrorKey]!)"
        default:
            return String(describing: error)
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: "true or false"
        case is String.Type: "text"
        case is Int.Type, is UInt8.Type: "a whole number"
        case is Double.Type: "a number"
        default: "a different kind of value"
        }
    }
}
