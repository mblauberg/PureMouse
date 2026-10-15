import CoreGraphics
import Foundation
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
    /// Every endpoint we listen on, keyed by interface and device index.
    private var endpoints: [Key: HIDPPDevice] = [:]
    private var sessions: [Key: Session] = [:]
    /// Receiver setup and Bluetooth adoption retries, cancelled when their interface goes away.
    private var interfaceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var adopting: Set<Key> = []
    /// Endpoints found not to be a configurable mouse (e.g. a keyboard on the same receiver),
    /// skipped until the config changes or mxd restarts.
    private var ignored: Set<Key> = []
    private var power: PowerObserver?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    private struct Key: Hashable {
        let interface: ObjectIdentifier
        let index: UInt8
        init(_ device: HIDPPDevice) {
            interface = ObjectIdentifier(device.interface)
            index = device.index
        }
    }

    private enum Adoption { case adopted, noAnswer, notAMouse }

    init(config: Config, configURL: URL) {
        self.config = config
        self.configURL = configURL
    }

    func start() {
        requestPermissions()
        LogiOptions.warnIfRunning()
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
        onSignal(SIGHUP) { $0.reload() }
        onSignal(SIGTERM) { $0.shutdown() }
        onSignal(SIGINT) { $0.shutdown() }
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

    /// A fresh child process (`mxd permissions`) sees new grants that this one cannot. When one
    /// arrives, quit cleanly and let launchd start mxd again with it. Only under launchd
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
        if interface.isReceiver {
            interfaceTasks[id] = Task {
                let receiver = HIDPPDevice(interface: interface, index: directDeviceIndex)
                defer { receiver.close() }
                do {
                    try await Receiver.enableNotifications(receiver)
                } catch {
                    Log.error("\(interface.product): enabling connection notifications failed: \(error)")
                }
                // Asleep or absent slots are adopted later, when they announce a connection.
                for slot in UInt8(1)...6 {
                    guard !Task.isCancelled else { return }
                    _ = await adopt(listen(interface, index: slot))
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
        for (key, session) in sessions where key.interface == id {
            session.close()
            sessions[key] = nil
        }
        for (key, endpoint) in endpoints where key.interface == id {
            endpoint.close()
            endpoints[key] = nil
        }
        ignored = ignored.filter { $0.interface != id }
    }

    /// Starts listening on a device index. Until a session adopts it, a receiver slot only
    /// watches for its device connecting.
    private func listen(_ interface: HIDInterface, index: UInt8) -> HIDPPDevice {
        let device = HIDPPDevice(interface: interface, index: index)
        endpoints[Key(device)] = device
        device.onEvent = { [weak self, weak device] report in
            guard let self, let device, report.featureIndex == Receiver.connectionNotification,
                  Receiver.isLinkEstablished(report) else { return }
            Task { _ = await self.adopt(device) }
        }
        return device
    }

    /// Creates a session if the endpoint is an awake HID++ 2.0 device with adjustable DPI or a
    /// configured control, so keyboards and other Logitech devices are left alone.
    private func adopt(_ device: HIDPPDevice) async -> Adoption {
        let key = Key(device)
        guard sessions[key] == nil else { return .adopted }
        guard !ignored.contains(key) else { return .notAMouse }
        guard endpoints[key] === device, !shuttingDown, adopting.insert(key).inserted else { return .noAnswer }
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
        // The device may have gone, or the daemon begun quitting, while we were asking.
        guard endpoints[key] === device, sessions[key] == nil, !shuttingDown else { return .noAnswer }
        Log.info("adopting \(name) on \(device.interface.product) index \(device.index)")
        let session = Session(device: device, name: name, controls: controls, config: config)
        sessions[key] = session
        session.configure()
        return .adopted
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
            _ = await adopt(endpoint)
        }
    }

    private func reload() {
        guard !shuttingDown else { return }
        do {
            config = try Config.load(from: configURL)
        } catch {
            Log.error("reload: \(error); keeping previous config")
            return
        }
        Log.info("config reloaded")
        ignored = []
        for (key, old) in sessions {
            old.close()
            let session = Session(device: old.device, name: old.name, controls: Array(old.controls.values),
                                  config: config, previouslyDiverted: old.divertedControls,
                                  scrollMode: old.currentScrollMode)
            sessions[key] = session
            session.configure()
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
        Task {
            await withTaskGroup(of: Void.self) { group in
                for session in all { group.addTask { await session.restore() } }
            }
            exit(0)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            Log.error("restore timed out")
            exit(0)
        }
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
