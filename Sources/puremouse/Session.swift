import Foundation
import HIDPP

/// One connected mouse: applies configuration to it and turns its diverted-button and wheel
/// events into actions and scrolling. Configuration is volatile on the device, so it is
/// re-applied on every reconnect.
@MainActor
final class Session {
    let device: HIDPPDevice
    let name: String
    let controls: [UInt16: ReprogControls.Control]
    private let config: Config
    private let bindings: [UInt16: Config.Binding]
    /// Controls a previous session diverted that this one no longer binds; released on apply.
    private var releasing: Set<UInt16>
    private let scroll: ScrollEngine?

    /// Last scroll mode set by toggling; survives reconnects, overriding the configured mode.
    private var scrollMode: SmartShift.Mode?
    private var held: [UInt16] = []
    private var gestureButton: UInt16?
    private var recognizer: GestureRecognizer
    private var wheelMultiplier = 15
    private var thumbInfo = ThumbWheel.Info(nativeResolution: 18, divertedResolution: 120)
    /// `config.dpi` snapped to the sensor's supported resolutions, once read.
    private var resolvedDPI: Int?
    private var configuring: Task<Void, Never>?
    private var toggling: Task<Void, Never>?
    /// Set by `close` and `restore`: nothing may touch the device on this session's behalf.
    private var finished = false

    init(device: HIDPPDevice, name: String, controls: [ReprogControls.Control], config: Config,
         previouslyDiverted: Set<UInt16> = [], scrollMode: SmartShift.Mode? = nil) {
        self.device = device
        self.name = name
        self.config = config
        let controls = Dictionary(controls.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        self.controls = controls
        bindings = config.bindings.filter { controls[$0.key]?.isDivertable == true }
        releasing = previouslyDiverted.subtracting(bindings.keys)
        self.scrollMode = scrollMode
        scroll = config.smoothScroll.map { ScrollEngine(profile: Self.profile($0, config)) }
        recognizer = GestureRecognizer(
            threshold: GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: config.dpi ?? 1000),
            repeatInterval: .milliseconds(config.gesture.repeatIntervalMs))
        device.onEvent = { [weak self] in self?.handle($0) }
        for cid in config.bindings.keys where controls[cid]?.isDivertable != true {
            Log.error("\(name): control 0x\(String(cid, radix: 16)) is missing or not divertable; skipped")
        }
    }

    /// Controls this session diverts or still owes a release, for handing to its replacement.
    var divertedControls: Set<UInt16> { releasing.union(bindings.keys) }
    var currentScrollMode: SmartShift.Mode? { scrollMode }

    func close() {
        finished = true
        configuring?.cancel()
        toggling?.cancel()
        scroll?.stop()
        device.onEvent = nil
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
        }
    }

    private func apply() async throws {
        // Resolve the event-bearing features first so their events can be routed.
        _ = try await device.hasFeature(ReprogControls.id)
        _ = try? await device.featureIndex(of: WirelessDeviceStatus.id)

        for cid in releasing {
            try await ReprogControls.setDiverted(device, cid: cid, divert: false, rawXY: false)
        }
        releasing = []
        for (cid, binding) in bindings {
            let isGesture = if case .gesture = binding { true } else { false }
            try await ReprogControls.setDiverted(device, cid: cid, divert: true,
                                                 rawXY: isGesture && controls[cid]?.supportsRawXY == true)
        }

        try await applyWheels()

        if try await device.hasFeature(AdjustableDPI.id) {
            if let dpi = config.dpi {
                try await AdjustableDPI.set(device, dpi: try await supportedDPI(near: dpi))
            }
            // Gesture distance is physical, so scale it by the resolution actually in effect.
            let dpi = try await AdjustableDPI.get(device)
            recognizer.threshold = GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: dpi)
        }
        let mode = scrollMode ?? config.scrollWheel?.mode?.smartShift
        let threshold = config.scrollWheel?.smartShiftThreshold
        if mode != nil || threshold != nil, try await device.hasFeature(SmartShift.id) {
            let current = try await SmartShift.get(device).mode
            try await SmartShift.set(device, mode: mode ?? current, autoDisengage: threshold)
        }
    }

    /// The configured DPI snapped to one the sensor accepts, read once per session. If the
    /// sensor cannot list its resolutions, the configured value is sent unchanged.
    private func supportedDPI(near configured: Int) async throws -> Int {
        if let resolvedDPI { return resolvedDPI }
        let resolutions: AdjustableDPI.Resolutions
        do {
            resolutions = try await AdjustableDPI.resolutions(device)
        } catch let error as CancellationError {
            throw error
        } catch HIDPPError.closed {
            throw HIDPPError.closed
        } catch {
            Log.error("\(name): reading supported DPI failed: \(error); setting \(configured) as configured")
            return configured
        }
        let dpi = resolutions.nearest(to: configured) ?? configured
        if dpi != configured {
            Log.info("\(name): dpi \(configured) is not supported; using \(dpi)")
        }
        resolvedDPI = dpi
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
        if try await device.hasFeature(ThumbWheel.id) {
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
    }

    /// Hands the mouse back in its native state: buttons undiverted and wheels reporting as
    /// ordinary HID scrolling, so it works without PureMouse. Used when PureMouse quits.
    func restore() async {
        finished = true
        configuring?.cancel()
        toggling?.cancel()
        scroll?.stop()
        // Wheels first: a silent wheel is worse than a diverted button. Each step stands alone,
        // so one failure does not skip the rest.
        if scroll != nil {
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
        if action == .toggleScrollMode {
            // Chain toggles so quick presses each flip the mode once, in order.
            toggling = Task { [previous = toggling] in
                await previous?.value
                await toggleScrollMode()
            }
        } else {
            SystemActions.perform(action)
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
            Log.debug("\(name): scroll mode \(next)")
        } catch {
            Log.error("\(name): toggle scroll mode failed: \(error)")
        }
    }
}
