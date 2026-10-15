import Foundation
import PureMouseKit
import HIDPP
import IOKit.hid
import IOKit.pwr_mgt

/// Finds HID++ mice on receivers and Bluetooth, keeps one `Session` per mouse, and re-applies
/// configuration after reconnects, system wake and config reloads (SIGHUP). On SIGTERM or
/// SIGINT it hands the mice back in their native state before exiting.
@MainActor
final class Daemon {
    private let monitor = HIDMonitor()
    private var config: Config
    private let configURL: URL
    /// Why the last load failed, while the previous (or an empty) config stays in effect.
    private var configError: String?
    /// The config file's bytes at the last load attempt, so a watched change that leaves them as
    /// they were does not reload.
    private var configBytes: Data?
    private let startedAt = Date.now
    private let permissions = Permissions.current
    private let logiOptionsRunning = !LogiOptions.running().isEmpty
    private var channel: StatusChannel?
    private var watcher: ConfigWatcher?
    /// Numbers interfaces in attach order, for device IDs that stay stable while the daemon runs.
    private var interfaceNumbers: [ObjectIdentifier: Int] = [:]
    private var nextInterfaceNumber = 1
    /// Every endpoint we listen on, keyed by interface and device index.
    private var endpoints: [Key: HIDPPDevice] = [:]
    private var sessions: [Key: Session] = [:]
    /// Receiver setup and Bluetooth adoption retries, cancelled when their interface goes away.
    private var interfaceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Receiver slots whose device did not answer, being tried again (see `adoptSlot`).
    private var slotRetries: [Key: Task<Void, Never>] = [:]
    private var adopting: Set<Key> = []
    /// Endpoints found not to be a configurable mouse (e.g. a keyboard on the same receiver),
    /// skipped until the config changes, a different device connects in the slot, or PureMouse
    /// restarts.
    private var ignored: Set<Key> = []
    /// The wireless product ID last announced in each receiver slot.
    private var slotProducts: [Key: UInt16] = [:]
    private var power: PowerObserver?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    /// Paused from the menu bar app (`Control.paused`): every mouse is native and none is adopted.
    private var paused = false
    /// Restoring the mice for a pause; resuming and quitting wait for it.
    private var pausing: Task<Void, Never>?
    /// Whether new sessions may be created.
    private var accepting: Bool { !shuttingDown && !paused }
    /// Set once the mice are restored, just before exit: the final status says not running.
    private var exiting = false

    private struct Key: Hashable {
        let interface: ObjectIdentifier
        let index: UInt8
        init(_ device: HIDPPDevice) {
            interface = ObjectIdentifier(device.interface)
            index = device.index
        }
    }

    /// `stopped`: not adopting now (paused or quitting), so do not retry.
    private enum Adoption { case adopted, noAnswer, notAMouse, stopped }

    init(configURL: URL) {
        self.configURL = configURL
        config = .empty
        if !loadConfig() {
            // Stay up with nothing configured rather than crash-loop under launchd; fixing the
            // file reloads it.
            Log.error("running unconfigured until the config loads")
        }
    }

    /// Loads the config file, keeping the current config if that fails. Returns whether it loaded.
    @discardableResult
    private func loadConfig() -> Bool {
        do {
            let data = try readConfig()
            config = try Config.loadLogged(from: data)
            configError = nil
            return true
        } catch {
            configError = ConfigCheck.message(for: error)
            Log.error("cannot load \(configURL.path): \(configError ?? "")")
            return false
        }
    }

    private func readConfig() throws -> Data {
        do {
            let data = try Data(contentsOf: configURL)
            configBytes = data
            return data
        } catch {
            configBytes = nil
            throw error
        }
    }

    func start() {
        requestPermissions()
        LogiOptions.warnIfRunning()
        StatusChannel.clearControl()
        channel = StatusChannel { [unowned self] in self.status(running: !self.exiting) }
        channel?.writeNow()
        channel?.onControl { [weak self] in self?.controlChanged() }
        monitor.onAttach = { [weak self] interface in self?.attached(interface) }
        monitor.onDetach = { [weak self] interface in self?.detached(interface) }
        let status = monitor.start()
        if status != kIOReturnSuccess {
            Log.error("opening HID devices failed: 0x\(String(UInt32(bitPattern: status), radix: 16)) (Input Monitoring permission?)")
        }
        power = PowerObserver { [weak self] in
            Log.info("system woke")
            self?.reconfigureAll()
        }
        watcher = ConfigWatcher(url: configURL) { [weak self] in self?.configFileChanged() }
        watcher?.start()
        onSignal(SIGHUP) { $0.reload() }
        onSignal(SIGTERM) { $0.shutdown() }
        onSignal(SIGINT) { $0.shutdown() }
    }

    // MARK: Status

    private func status(running: Bool) -> Status {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return Status(
            pid: getpid(), startedAt: startedAt, version: version, running: running, paused: paused,
            permissions: .init(accessibility: permissions.contains(.accessibility),
                               inputMonitoring: permissions.contains(.inputMonitoring)),
            logiOptionsRunning: logiOptionsRunning,
            config: .init(path: configURL.path, error: configError),
            devices: running ? sessions.values.map(\.status).sorted { $0.id < $1.id } : [],
            capture: nil)
    }

    private func statusChanged() {
        channel?.setNeedsWrite()
    }

    // MARK: Control

    /// The menu bar app changed `control.json`. A missing file means no requests.
    private func controlChanged() {
        guard !shuttingDown else { return }
        let control: Control
        if FileManager.default.fileExists(atPath: Companion.controlURL.path) {
            guard let read = Companion.read(Control.self, from: Companion.controlURL) else {
                Log.error("ignoring unreadable \(Companion.controlURL.path)")
                return
            }
            control = read
        } else {
            control = Control()
        }
        if control.paused != paused { control.paused ? pause() : resume() }
    }

    /// Returns every mouse to native behaviour and stops adopting until `resume`.
    private func pause() {
        Log.info("paused")
        paused = true
        let all = Array(sessions.values)
        sessions = [:]
        for session in all { watch(session.device) }
        pausing = Task { [previous = pausing] in
            await previous?.value
            await withTaskGroup(of: Void.self) { group in
                for session in all { group.addTask { await session.restore() } }
            }
        }
        statusChanged()
    }

    private func resume() {
        Log.info("resumed")
        paused = false
        statusChanged()
        Task { [pausing] in
            await pausing?.value
            await adoptStragglers()
        }
    }

    private func onSignal(_ number: Int32, _ handler: @escaping (Daemon) -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { if let self { handler(self) } } }
        source.resume()
        signalSources.append(source)
    }

    private func requestPermissions() {
        let granted = Permissions.current
        Permissions.requestMissing(granted)
        if granted != .all { restartWhenGranted(beyond: granted) }
    }

    /// A fresh child process (`puremouse permissions`) sees new grants that this one cannot. When
    /// one arrives, quit cleanly and let launchd start PureMouse again with it. Only under launchd
    /// (parent pid 1): an instance run from a terminal would not come back.
    private func restartWhenGranted(beyond granted: Permissions) {
        guard getppid() == 1, let executable = Bundle.main.executableURL else { return }
        Task {
            var delay = 2
            while !shuttingDown {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
                if !(await Self.permissions(checkedBy: executable)).subtracting(granted).isEmpty {
                    Log.info("permission granted; restarting to apply it")
                    shutdown()
                }
            }
        }
    }

    private static func permissions(checkedBy executable: URL) async -> Permissions {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["permissions"]
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: Permissions(rawValue: $0.terminationStatus)) }
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }

    // MARK: Interfaces

    private func attached(_ interface: HIDInterface) {
        Log.info("found \(interface.product) (\(interface.transport))")
        let id = ObjectIdentifier(interface)
        interfaceNumbers[id] = nextInterfaceNumber
        nextInterfaceNumber += 1
        if interface.isReceiver {
            interfaceTasks[id] = Task {
                let receiver = HIDPPDevice(interface: interface, index: directDeviceIndex)
                defer { receiver.close() }
                do {
                    try await Receiver.enableNotifications(receiver)
                } catch {
                    Log.error("\(interface.product): enabling connection notifications failed: \(error)")
                }
                // Slots still silent after adoptSlot's few retries (asleep or empty) are adopted
                // later, when they announce a connection.
                for slot in UInt8(1)...6 {
                    guard !Task.isCancelled else { return }
                    await adoptSlot(listen(interface, index: slot))
                }
            }
        } else {
            let device = listen(interface, index: directDeviceIndex)
            interfaceTasks[id] = Task {
                // A Bluetooth mouse has no connection notifications, so keep trying until it
                // answers; it may still be waking or finishing pairing.
                for delay in [0, 2, 5, 10, 30] + Array(repeating: 60, count: 1000) {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    if await adopt(device) != .noAnswer { return }
                }
            }
        }
    }

    private func detached(_ interface: HIDInterface) {
        Log.info("lost \(interface.product)")
        let id = ObjectIdentifier(interface)
        interfaceTasks.removeValue(forKey: id)?.cancel()
        for (key, retry) in slotRetries where key.interface == id {
            retry.cancel()
            slotRetries[key] = nil
        }
        for (key, session) in sessions where key.interface == id {
            session.close()
            sessions[key] = nil
        }
        for (key, endpoint) in endpoints where key.interface == id {
            endpoint.close()
            endpoints[key] = nil
        }
        ignored = ignored.filter { $0.interface != id }
        slotProducts = slotProducts.filter { $0.key.interface != id }
        interfaceNumbers[id] = nil
        statusChanged()
    }

    /// Starts listening on a device index. Until a session adopts it, a receiver slot only
    /// watches for its device connecting.
    private func listen(_ interface: HIDInterface, index: UInt8) -> HIDPPDevice {
        let device = HIDPPDevice(interface: interface, index: index)
        endpoints[Key(device)] = device
        watch(device)
        return device
    }

    /// Routes an endpoint's events to the daemon, as when no session owns it.
    private func watch(_ device: HIDPPDevice) {
        device.onEvent = { [weak self, weak device] report in
            guard let self, let device, report.featureIndex == Receiver.connectionNotification else { return }
            self.slotAnnounced(device, report)
        }
    }

    /// A connection notification for a slot with no session. A different device in the slot
    /// (say a mouse paired where a keyboard was) is identified afresh even if the slot was
    /// ignored; the first notification after attach re-checks an ignored device once.
    private func slotAnnounced(_ device: HIDPPDevice, _ report: Report) {
        let key = Key(device)
        if let product = Receiver.productID(report), slotProducts[key] != product {
            slotProducts[key] = product
            ignored.remove(key)
        }
        guard Receiver.isLinkEstablished(report) else { return }
        Task { await adoptSlot(device) }
    }

    /// Adopts a receiver slot. A device that does not answer, perhaps still settling after a
    /// wake or busy with another request, is tried again after 1, 2, 4 and 8 seconds; one that
    /// is really away announces itself when it connects.
    private func adoptSlot(_ device: HIDPPDevice) async {
        let key = Key(device)
        guard await adopt(device) == .noAnswer, slotRetries[key] == nil,
              endpoints[key] === device, accepting else { return }
        slotRetries[key] = Task {
            defer { if !Task.isCancelled { slotRetries[key] = nil } }
            for delay in [1, 2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, endpoints[key] === device, accepting else { return }
                if await adopt(device) != .noAnswer { return }
            }
        }
    }

    /// Creates a session if the endpoint is an awake HID++ 2.0 device with adjustable DPI or a
    /// configured control, so keyboards and other Logitech devices are left alone.
    private func adopt(_ device: HIDPPDevice) async -> Adoption {
        let key = Key(device)
        guard sessions[key] == nil else { return .adopted }
        guard !ignored.contains(key) else { return .notAMouse }
        guard accepting else { return .stopped }
        guard endpoints[key] === device, adopting.insert(key).inserted else { return .noAnswer }
        defer { adopting.remove(key) }
        let result = await identify(device)
        if result == .notAMouse { ignored.insert(key) }
        return result
    }

    private func identify(_ device: HIDPPDevice) async -> Adoption {
        let key = Key(device)
        guard let version = await device.protocolVersion() else { return .noAnswer }
        guard version.major >= 2 else { return .notAMouse }
        let controls: [ReprogControls.Control]
        let hasDPI: Bool
        do {
            controls = try await device.hasFeature(ReprogControls.id) ? ReprogControls.controls(device) : []
            hasDPI = try await device.hasFeature(AdjustableDPI.id)
        } catch {
            return .noAnswer
        }
        let configured = Set(config.bindings.keys)
        guard hasDPI || controls.contains(where: { configured.contains($0.cid) }) else { return .notAMouse }
        let name = (try? await DeviceName.get(device)) ?? "device \(device.index)"
        // The device may have gone, or the daemon paused or begun quitting, while we were asking.
        guard accepting else { return .stopped }
        guard endpoints[key] === device, sessions[key] == nil else { return .noAnswer }
        Log.info("adopting \(name) on \(device.interface.product) index \(device.index)")
        let session = Session(device: device, name: name, id: deviceID(key), controls: controls, config: config)
        add(session, key)
        return .adopted
    }

    private func deviceID(_ key: Key) -> String {
        "\(interfaceNumbers[key.interface] ?? 0)-\(key.index)"
    }

    private func add(_ session: Session, _ key: Key) {
        sessions[key] = session
        session.onChange = { [weak self] in self?.statusChanged() }
        session.configure()
        statusChanged()
    }

    // MARK: Reconfiguration

    private func reconfigureAll() {
        // Give the receiver and Bluetooth stack a moment after wake.
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !shuttingDown else { return }
            sessions.values.forEach { $0.configure() }
            await adoptStragglers()
        }
    }

    /// Retries endpoints that answered nothing earlier, such as a mouse asleep at attach time.
    private func adoptStragglers() async {
        for (key, endpoint) in endpoints where sessions[key] == nil {
            if endpoint.interface.isReceiver {
                await adoptSlot(endpoint)
            } else {
                _ = await adopt(endpoint)
            }
        }
    }

    /// The watched config file may have changed: reload if its bytes did.
    private func configFileChanged() {
        guard (try? Data(contentsOf: configURL)) != configBytes else { return }
        Log.info("config file changed")
        reload()
    }

    private func reload() {
        guard !shuttingDown else { return }
        defer { statusChanged() }
        let previous = config
        guard loadConfig() else {
            Log.error("reload failed; keeping previous config")
            return
        }
        Log.info("config reloaded")
        // A DPI picked by cycleDPI lasts until the configured DPI or presets change.
        let keepLiveDPI = previous.dpi == config.dpi && previous.dpiPresets == config.dpiPresets
        ignored = []
        for (key, old) in sessions {
            old.close()
            var inherited = old.inheritance
            if !keepLiveDPI { inherited.liveDPI = nil }
            add(Session(device: old.device, name: old.name, id: old.id, controls: Array(old.controls.values),
                        config: config, inheriting: inherited), key)
        }
        Task { await adoptStragglers() }
    }

    /// Restores every mouse to native behaviour, then exits. Gives up after two seconds so a
    /// sleeping mouse cannot hold up logout; it resets itself on its next reconnect anyway.
    private func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        Log.info("quitting")
        let all = Array(sessions.values)
        Task { [pausing] in
            await withTaskGroup(of: Void.self) { group in
                for session in all { group.addTask { await session.restore() } }
                if let pausing { group.addTask { await pausing.value } }
            }
            exitReporting()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            Log.error("restore timed out")
            exitReporting()
        }
    }

    /// The final status, `running: false`, is the last thing written.
    private func exitReporting() -> Never {
        exiting = true
        channel?.writeNow()
        exit(0)
    }
}

/// Calls `onWake` after the system wakes from sleep.
@MainActor
final class PowerObserver {
    private let onWake: () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    fileprivate var rootPort: io_connect_t = 0

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &port, { ctx, _, message, argument in
            MainActor.assumeIsolated {
                let observer = Unmanaged<PowerObserver>.fromOpaque(ctx!).takeUnretainedValue()
                observer.received(message, argument)
            }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }

    private func received(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        // iokit_common_msg() values; the C macros are not imported into Swift.
        let canSystemSleep: natural_t = 0xE000_0270, systemWillSleep: natural_t = 0xE000_0280
        let systemHasPoweredOn: natural_t = 0xE000_0300
        switch message {
        case canSystemSleep, systemWillSleep:
            // Sleep must be acknowledged or the system waits for a timeout.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
