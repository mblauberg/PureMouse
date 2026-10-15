import Foundation
import PureMouseKit
import HIDPP

/// One connected mouse: applies configuration to it and turns its diverted-button and wheel
/// events into actions and scrolling. Configuration is volatile on the device, so it is
/// re-applied on every reconnect.
@MainActor
final class Session {
    let device: HIDPPDevice
    let name: String
    /// Reported in `Status.Device.id`: stable while the daemon runs.
    let id: String
    let controls: [UInt16: ReprogControls.Control]
    /// Called after anything in `status` may have changed.
    var onChange: (() -> Void)?
    /// Called with the first control pressed while capturing; that press performs nothing.
    var onCapture: ((UInt16) -> Void)?
    private let config: Config
    private let bindings: [UInt16: Config.Binding]
    /// Controls a previous session diverted that this one no longer binds; released on apply.
    private var releasing: Set<UInt16>
    private let scroll: ScrollEngine?
    /// Whether the wheels may be diverted to PureMouse, by this session or one it replaced, so
    /// `restore` must hand them back even if this session's config never diverts them.
    private(set) var wheelsMayBeDiverted: Bool

    /// Last scroll mode set by toggling; survives reconnects, overriding the configured mode.
    private var scrollMode: SmartShift.Mode?
    private var held: [UInt16] = []
    private var gestureButton: UInt16?
    private var recognizer: GestureRecognizer
    private var wheelMultiplier = 15
    private var thumbInfo = ThumbWheel.Info(nativeResolution: 18, divertedResolution: 120)
    /// The sensor's supported resolutions, read once per mouse (inherited across reloads).
    private var resolutions: AdjustableDPI.Resolutions?
    /// Targets already reported as snapped to a supported resolution, so each is logged once.
    private var snapLogged: Set<Int> = []
    /// Reported state; see `status`.
    private var online: Bool
    private var dpi: Int?
    private var wheelMode: SmartShift.Mode?
    private var battery: UnifiedBattery.State?
    private var hasSmartShift: Bool
    private var hasThumbWheel: Bool
    private var configuring: Task<Void, Never>?
    /// Device actions (toggle scroll mode, cycle DPI), chained so quick presses apply in order.
    private var deviceAction: Task<Void, Never>?
    /// Controls diverted only so select-by-pressing can see them; nil when not capturing.
    private var capturing: Set<UInt16>?
    /// Capture diversion changes, chained so they reach the device in order.
    private var diverting: Task<Void, Never>?
    /// Set by `cycleDPI`, overriding `config.dpi`: kept across reconnects and reloads, cleared by
    /// a reload that changes `dpi` or `dpiPresets` (see `Daemon.reload`).
    private var liveDPI: Int?
    /// Set by `close` and `restore`: nothing may touch the device on this session's behalf.
    private var finished = false

    /// What a session hands to the one replacing it on reload: device state that outlives a
    /// config, and what the device may still have diverted.
    struct Inherited {
        var diverted: Set<UInt16> = []
        var wheelsMayBeDiverted = false
        var scrollMode: SmartShift.Mode?
        var liveDPI: Int?
        var resolutions: AdjustableDPI.Resolutions?
        var online = true
        var dpi: Int?
        var wheelMode: SmartShift.Mode?
        var battery: UnifiedBattery.State?
        var hasSmartShift = false
        var hasThumbWheel = false
    }

    init(device: HIDPPDevice, name: String, id: String, controls: [ReprogControls.Control], config: Config,
         inheriting inherited: Inherited = Inherited()) {
        self.device = device
        self.name = name
        self.id = id
        self.config = config
        let controls = Dictionary(controls.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        self.controls = controls
        bindings = config.bindings.filter { controls[$0.key]?.isDivertable == true }
        releasing = inherited.diverted.subtracting(bindings.keys)
        scrollMode = inherited.scrollMode
        liveDPI = inherited.liveDPI
        resolutions = inherited.resolutions
        online = inherited.online
        dpi = inherited.dpi
        wheelMode = inherited.wheelMode
        battery = inherited.battery
        hasSmartShift = inherited.hasSmartShift
        hasThumbWheel = inherited.hasThumbWheel
        scroll = config.smoothScroll.flatMap { $0.enabled ? ScrollEngine(profile: Self.profile($0, config)) : nil }
        self.wheelsMayBeDiverted = inherited.wheelsMayBeDiverted || scroll != nil
        recognizer = GestureRecognizer(
            threshold: GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: config.dpi ?? 1000),
            repeatInterval: .milliseconds(config.gesture.repeatIntervalMs))
        device.onEvent = { [weak self] in self?.handle($0) }
        for cid in config.bindings.keys where controls[cid]?.isDivertable != true {
            Log.error("\(name): control 0x\(String(cid, radix: 16)) is missing or not divertable; skipped")
        }
    }

    /// Controls this session diverts or still owes a release, for handing to its replacement.
    var divertedControls: Set<UInt16> { releasing.union(bindings.keys).union(capturing ?? []) }

    var inheritance: Inherited {
        Inherited(diverted: divertedControls, wheelsMayBeDiverted: wheelsMayBeDiverted, scrollMode: scrollMode,
                  liveDPI: liveDPI,
                  resolutions: resolutions, online: online, dpi: dpi, wheelMode: wheelMode,
                  battery: battery, hasSmartShift: hasSmartShift, hasThumbWheel: hasThumbWheel)
    }

    var status: Status.Device {
        Status.Device(
            id: id, name: name, connection: device.interface.isReceiver ? .receiver : .bluetooth,
            online: online, battery: battery.flatMap(Self.status), dpi: dpi, dpiSteps: resolutions?.values ?? [],
            wheelMode: wheelMode.map { $0 == .ratchet ? .ratchet : .freespin },
            hasSmartShift: hasSmartShift, hasThumbWheel: hasThumbWheel,
            controls: controls.values.filter { $0.isDivertable && !$0.isVirtual }.map(\.cid).sorted()
                .map { Status.Device.Control(cid: $0, name: Config.Button(cid: $0)?.rawValue) })
    }

    private static func status(_ battery: UnifiedBattery.State) -> Status.Device.Battery? {
        let level: Status.Device.Battery.Level
        switch battery.level {
        case .critical: level = .critical
        case .low: level = .low
        case .good: level = .good
        case .full: level = .full
        case nil:
            guard let percent = battery.percent else { return nil }
            level = percent <= 5 ? .critical : percent <= 20 ? .low : percent < 90 ? .good : .full
        }
        return Status.Device.Battery(percent: battery.percent, level: level, charging: battery.isCharging)
    }

    private func changed() {
        onChange?()
    }

    func close() {
        finished = true
        configuring?.cancel()
        deviceAction?.cancel()
        diverting?.cancel()
        scroll?.stop()
        device.onEvent = nil
    }

    // MARK: Select by pressing

    /// Diverts every pressable control not already bound, so the next press of any control
    /// reaches `onCapture` instead of macOS or an action.
    func beginCapture() {
        guard !finished, capturing == nil else { return }
        let extras = Set(controls.values.filter { $0.isDivertable && !$0.isVirtual }.map(\.cid))
            .subtracting(bindings.keys)
        capturing = extras
        releasing.subtract(extras)
        divert { session in
            for cid in extras {
                guard session.capturing != nil else { return }
                try await ReprogControls.setDiverted(session.device, cid: cid, divert: true, rawXY: false)
            }
        }
    }

    /// Hands the controls diverted for capture back to macOS.
    func endCapture() {
        guard let extras = capturing else { return }
        capturing = nil
        releasing.formUnion(extras)
        divert { session in
            for cid in session.releasing {
                try await ReprogControls.setDiverted(session.device, cid: cid, divert: false, rawXY: false)
                session.releasing.remove(cid)
            }
        }
    }

    private func divert(_ body: @escaping (Session) async throws -> Void) {
        guard !finished else { return }
        diverting = Task { [previous = diverting] in
            await previous?.value
            guard !finished else { return }
            do {
                try await body(self)
            } catch {
                // Usually asleep: the next apply diverts or releases them.
                Log.debug("\(name): capture diversion failed: \(error)")
            }
        }
    }

    private static func profile(_ s: Config.SmoothScroll, _ config: Config) -> ScrollEngine.Profile {
        ScrollEngine.Profile(speed: s.speed, horizontalSpeed: s.horizontalSpeed, acceleration: s.acceleration,
                             smoothing: .milliseconds(s.smoothingMs),
                             shiftScrollsHorizontally: s.shiftScrollsHorizontally,
                             invertVertical: config.scrollWheel?.inverted ?? false,
                             invertHorizontal: config.thumbWheel?.inverted ?? false)
    }

    // MARK: Configuration

    /// (Re)applies all settings after `delay`, retrying a few times if the device does not
    /// answer. Safe to call repeatedly; a newer call supersedes an older one.
    func configure(after delay: Duration = .zero) {
        guard !finished else { return }
        configuring?.cancel()
        held = []
        gestureButton = nil
        configuring = Task {
            try? await Task.sleep(for: delay)
            for attempt in 1...3 {
                guard !Task.isCancelled else { return }
                do {
                    try await apply()
                    Log.info("\(name): configured")
                    return
                } catch is CancellationError {
                    return
                } catch HIDPPError.closed {
                    return
                } catch {
                    Log.error("\(name): configure attempt \(attempt) failed: \(error)")
                }
                // Usually the mouse is asleep; its reconnect event will also trigger a retry.
                try? await Task.sleep(for: .seconds(5))
            }
            guard !Task.isCancelled, !finished, online else { return }
            online = false
            changed()
        }
    }

    private func apply() async throws {
        // Resolve the event-bearing features first so their events can be routed.
        _ = try await device.hasFeature(ReprogControls.id)
        _ = try? await device.featureIndex(of: WirelessDeviceStatus.id)
        _ = try? await device.featureIndex(of: UnifiedBattery.id)

        for cid in releasing {
            try await ReprogControls.setDiverted(device, cid: cid, divert: false, rawXY: false)
            releasing.remove(cid)
        }
        for (cid, binding) in bindings {
            let isGesture = if case .gesture = binding { true } else { false }
            try await ReprogControls.setDiverted(device, cid: cid, divert: true,
                                                 rawXY: isGesture && controls[cid]?.supportsRawXY == true)
        }
        for cid in capturing ?? [] {
            try await ReprogControls.setDiverted(device, cid: cid, divert: true, rawXY: false)
        }

        try await applyWheels()

        if try await device.hasFeature(AdjustableDPI.id) {
            try await readResolutions()
            if let target = liveDPI ?? config.dpi {
                try await AdjustableDPI.set(device, dpi: supportedDPI(near: target))
            }
            try await readDPI()
        }
        hasSmartShift = try await device.hasFeature(SmartShift.id)
        if hasSmartShift {
            let mode = scrollMode ?? config.scrollWheel?.mode?.smartShift
            let threshold = config.scrollWheel?.smartShiftThreshold
            let current = try await SmartShift.get(device).mode
            if mode != nil || threshold != nil {
                try await SmartShift.set(device, mode: mode ?? current, autoDisengage: threshold)
            }
            wheelMode = mode ?? current
        }
        await readBattery()
        online = true
        changed()
    }

    /// Battery state is informational: a mouse without 0x1004, or one that fails to answer,
    /// reports none.
    private func readBattery() async {
        guard (try? await device.hasFeature(UnifiedBattery.id)) == true else { return }
        do {
            battery = try await UnifiedBattery.status(device)
        } catch {
            Log.debug("\(name): reading battery failed: \(error)")
        }
    }

    /// Reads the resolution in effect, for the status and the gesture distance, which is
    /// physical and so scales with it.
    private func readDPI() async throws {
        let current = try await AdjustableDPI.get(device)
        dpi = current
        recognizer.threshold = GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: current)
    }

    /// Reads the sensor's supported resolutions once per mouse. A failure is logged and retried
    /// on the next apply; meanwhile DPI targets are sent unchanged.
    private func readResolutions() async throws {
        guard resolutions == nil else { return }
        do {
            resolutions = try await AdjustableDPI.resolutions(device)
        } catch let error as CancellationError {
            throw error
        } catch HIDPPError.closed {
            throw HIDPPError.closed
        } catch {
            Log.error("\(name): reading supported DPI failed: \(error); DPI is set as configured")
        }
    }

    /// `target` snapped to a resolution the sensor accepts, or unchanged if the list is unknown.
    private func supportedDPI(near target: Int) -> Int {
        let dpi = resolutions?.nearest(to: target) ?? target
        if dpi != target, snapLogged.insert(target).inserted {
            Log.info("\(name): dpi \(target) is not supported; using \(dpi)")
        }
        return dpi
    }

    /// With smooth scrolling, both wheels report to PureMouse at full resolution and direction is
    /// handled in software. Without it, they report as ordinary HID scrolling (Logi Options+
    /// leaves them diverted, which would leave them dead without it), inverted in hardware.
    private func applyWheels() async throws {
        // Taking the wheels over without permission to post scroll events would silence them.
        let smooth = scroll != nil && Permissions.current.contains(.accessibility)
        if scroll != nil && !smooth { Log.error("\(name): no Accessibility permission; leaving the wheels native") }
        if try await device.hasFeature(HiResWheel.id) {
            var inverted = false
            if smooth {
                wheelMultiplier = try await HiResWheel.multiplier(device)
            } else if let configured = config.scrollWheel?.inverted {
                inverted = configured
            } else {
                inverted = try await HiResWheel.mode(device).inverted  // not configured: keep
            }
            try await HiResWheel.setMode(device, .init(diverted: smooth, highResolution: smooth, inverted: inverted))
        }
        hasThumbWheel = try await device.hasFeature(ThumbWheel.id)
        if hasThumbWheel {
            var inverted = false
            if smooth {
                thumbInfo = try await ThumbWheel.info(device)
            } else if let configured = config.thumbWheel?.inverted {
                inverted = configured
            } else {
                inverted = try await ThumbWheel.reporting(device).inverted
            }
            try await ThumbWheel.setReporting(device, .init(diverted: smooth, inverted: inverted))
        }
        if !smooth { wheelsMayBeDiverted = false }
    }

    /// Hands the mouse back in its native state: buttons undiverted and wheels reporting as
    /// ordinary HID scrolling, so it works without PureMouse. Used when PureMouse quits.
    func restore() async {
        finished = true
        configuring?.cancel()
        deviceAction?.cancel()
        diverting?.cancel()
        scroll?.stop()
        // Wheels first: a silent wheel is worse than a diverted button. Each step stands alone,
        // so one failure does not skip the rest. A replaced session may have diverted them even
        // if this one would not, e.g. after a reload that turned smooth scrolling off.
        if wheelsMayBeDiverted {
            await attempt("restore wheel") {
                if try await self.device.hasFeature(HiResWheel.id) {
                    try await HiResWheel.setMode(self.device, .init(diverted: false, highResolution: false,
                                                                    inverted: self.config.scrollWheel?.inverted ?? false))
                }
            }
            await attempt("restore thumb wheel") {
                if try await self.device.hasFeature(ThumbWheel.id) {
                    try await ThumbWheel.setReporting(self.device, .init(diverted: false,
                                                                         inverted: self.config.thumbWheel?.inverted ?? false))
                }
            }
        }
        for cid in divertedControls {
            await attempt("release control 0x\(String(cid, radix: 16))") {
                try await ReprogControls.setDiverted(self.device, cid: cid, divert: false, rawXY: false)
            }
        }
        Log.info("\(name): restored native behaviour")
    }

    private func attempt(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            Log.error("\(name): \(what) failed: \(error)")
        }
    }

    // MARK: Events

    private func handle(_ report: Report) {
        guard !finished else { return }
        if report.featureIndex == Receiver.connectionNotification {
            if Receiver.isLinkEstablished(report) {
                Log.info("\(name): link up")
                configure()
            } else {
                scroll?.stop()
                if online {
                    online = false
                    changed()
                }
            }
            return
        }
        switch device.feature(at: report.featureIndex) {
        case HiResWheel.id:
            switch HiResWheel.parse(function: report.function, params: report.params) {
            case .scroll(let delta, _): scroll?.wheel(delta, perNotch: wheelMultiplier)
            case .ratchet(let engaged): Log.debug("\(name): ratchet \(engaged ? "engaged" : "released")")
            case nil: break
            }
        case ThumbWheel.id:
            if let event = ThumbWheel.parse(function: report.function, params: report.params), event.rotation != 0 {
                scroll?.thumb(event.rotation, perRotation: thumbInfo.divertedResolution,
                              nativeSteps: thumbInfo.nativeResolution)
            }
        case ReprogControls.id:
            switch ReprogControls.parse(function: report.function, params: report.params) {
            case .buttons(let cids): buttonsChanged(cids)
            case .rawXY(let dx, let dy): moved(dx: Int(dx), dy: Int(dy))
            case nil: break
            }
        case UnifiedBattery.id:
            if let state = UnifiedBattery.parse(function: report.function, params: report.params), state != battery {
                Log.debug("\(name): battery \(state.percent.map { "\($0)%" } ?? "?") \(state.isCharging ? "charging" : "")")
                battery = state
                changed()
            }
        case WirelessDeviceStatus.id:
            if WirelessDeviceStatus.needsReconfiguration(function: report.function, params: report.params) {
                Log.info("\(name): reconnected")
                configure(after: .milliseconds(100))
            }
        default:
            break
        }
    }

    private func buttonsChanged(_ cids: [UInt16]) {
        let pressed = cids.filter { !held.contains($0) }
        let released = held.filter { !cids.contains($0) }
        held = cids
        released.forEach(release)
        if capturing != nil {
            if let first = pressed.first { onCapture?(first) }
            return
        }
        pressed.forEach(press)
    }

    private func press(_ cid: UInt16) {
        Log.debug("\(name): press 0x\(String(cid, radix: 16))")
        switch bindings[cid] {
        case .action(let action):
            perform(action)
        case .gesture:
            guard gestureButton == nil else { return }
            gestureButton = cid
            recognizer.begin()
        case nil:
            break
        }
    }

    private func release(_ cid: UInt16) {
        guard cid == gestureButton, case .gesture(let gesture) = bindings[cid] else { return }
        gestureButton = nil
        if recognizer.end() { perform(gesture.click) }
    }

    private func moved(dx: Int, dy: Int) {
        guard let cid = gestureButton, case .gesture(let gesture) = bindings[cid],
              let direction = recognizer.move(dx: dx, dy: dy) else { return }
        Log.debug("\(name): gesture \(direction)")
        perform(gesture.action(for: direction))
    }

    private func perform(_ action: Action) {
        guard action.actsOnDevice else {
            SystemActions.perform(action)
            return
        }
        // Chained so quick presses each take effect once, in order.
        deviceAction = Task { [previous = deviceAction] in
            await previous?.value
            if action == .cycleDPI {
                await cycleDPI()
            } else {
                await toggleScrollMode()
            }
        }
    }

    private func cycleDPI() async {
        guard !finished else { return }
        guard !config.dpiPresets.isEmpty else {
            Log.error("\(name): cycleDPI needs dpiPresets in the config")
            return
        }
        do {
            guard try await device.hasFeature(AdjustableDPI.id) else { return }
            let current = if let dpi { dpi } else { try await AdjustableDPI.get(device) }
            guard let next = Config.nextPreset(config.dpiPresets.map(supportedDPI(near:)), after: current),
                  !finished else { return }
            try await AdjustableDPI.set(device, dpi: next)
            liveDPI = next
            try await readDPI()
            Log.debug("\(name): dpi \(next)")
            changed()
        } catch {
            Log.error("\(name): cycle DPI failed: \(error)")
        }
    }

    private func toggleScrollMode() async {
        guard !finished else { return }
        do {
            let current = try await SmartShift.get(device).mode
            guard !finished else { return }
            let next: SmartShift.Mode = current == .ratchet ? .freespin : .ratchet
            try await SmartShift.set(device, mode: next)
            scrollMode = next
            wheelMode = next
            changed()
            Log.debug("\(name): scroll mode \(next)")
        } catch {
            Log.error("\(name): toggle scroll mode failed: \(error)")
        }
    }
}
