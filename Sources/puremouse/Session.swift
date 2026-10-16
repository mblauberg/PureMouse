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
    /// Controls a user can press (divertable, not virtual), by CID, as reported in `status`.
    let pressable: [Status.Device.Control]
    /// Called after anything in `status` may have changed.
    var onChange: (() -> Void)?
    /// Called with the first control pressed while capturing; that press performs nothing.
    var onCapture: ((UInt16) -> Void)?
    /// Called with each connection notification before the session acts on it; true when the slot
    /// now holds a different device and the daemon has closed this session to adopt that one.
    var onConnection: ((Report) -> Bool)?
    let config: Config
    /// What applies where no app entry matches.
    let global: Config.AppSettings
    /// Controls bound globally or in any app, all diverted; true for those diverted with raw
    /// motion because some scope binds them to a gesture.
    let bound: [UInt16: Bool]
    /// Controls some app binds its own way, and whether any app sets the thumb wheel: only then
    /// is the app looked up, at a press of one of them or a thumb-wheel movement. Scroll bursts
    /// look it up when `appProfiles` is not empty.
    let appButtons: Set<UInt16>
    let appThumbWheel: Bool
    /// Smooth scrolling profiles of the apps that set it, by lowercased bundle ID.
    let appProfiles: [String: ScrollEngine.Profile]
    let globalProfile: ScrollEngine.Profile
    /// Controls a previous session diverted that this one no longer binds; released on apply.
    var releasing: Set<UInt16>
    let scroll: ScrollEngine?
    /// Whether any scope scrolls smoothly, so the main wheel is diverted too.
    let smoothAnywhere: Bool
    /// Whether the wheels may be diverted to PureMouse, by this session or one it replaced, so
    /// `restore` must hand them back even if this session's config never diverts them.
    var wheelsMayBeDiverted: Bool

    /// Buttons down, the gesture held and native clicks posted (`HeldButtons`).
    var held = HeldButtons()
    /// The thumb wheel settings of the current movement and its step counter.
    var thumbSettings = Config.ThumbWheel()
    var thumbStepper = ThumbStepper(threshold: 1)
    var thumbLast: ContinuousClock.Instant?
    /// A pause this long ends a thumb-wheel movement, like the wheel's own stop report.
    static let thumbGap: Duration = .milliseconds(500)
    var recognizer: GestureRecognizer
    var wheelMultiplier = 15
    var thumbInfo = ThumbWheel.Info(nativeResolution: 18, divertedResolution: 120)
    /// Targets already reported as snapped to a supported resolution, so each is logged once.
    private var snapLogged: Set<Int> = []
    /// Device state that outlives a config (see `DeviceState`).
    var state: DeviceState
    var hapticCapabilities: Haptic.Capabilities?
    var hapticMissingLogged = false
    var unsupportedHaptics: Set<HapticWaveform> = []
    private var configuring: Task<Void, Never>?
    /// Device actions (toggle scroll mode, cycle DPI, haptics) and `apply`'s DPI and scroll mode
    /// writes, one at a time in the order asked, each reading what is wanted (`liveDPI`,
    /// `scrollMode`) as it runs, so a press and a reconfiguration cannot overwrite each other.
    let deviceActions = SerialChain()
    /// Controls diverted only so select-by-pressing can see them; nil when not capturing.
    var capturing: Set<UInt16>?
    /// Every change to which controls are diverted and to the wheels, by configuration, capture or
    /// a handoff, chained so each runs alone and they reach the device in the order they were asked
    /// for. It starts after the chain of the session this one replaced.
    let diversion: SerialChain
    /// Set by `close` and `restore`: nothing may touch the device on this session's behalf.
    var finished = false
    /// The pointer is on another Mac (Universal Control): wheels and controls are left native so
    /// macOS forwards them there; everything else stays applied. Changed by `setAway`.
    var away = false

    /// What the session knows of the mouse beyond its config: kept across reconnects and handed
    /// to the session replacing this one on reload. Online, DPI, wheel mode, battery and the
    /// feature flags are reported in `status`.
    struct DeviceState {
        /// Last scroll mode set by toggling, overriding the configured mode.
        var scrollMode: SmartShift.Mode?
        /// Set by `cycleDPI`, overriding `config.dpi`; cleared by a reload that changes `dpi` or
        /// `dpiPresets` (see `Daemon.reload`) and by `useConfiguredDPI`.
        var liveDPI: Int?
        /// The sensor's supported resolutions, read once per mouse.
        var resolutions: AdjustableDPI.Resolutions?
        var online = true
        var dpi: Int?
        var wheelMode: SmartShift.Mode?
        var battery: UnifiedBattery.State?
        /// Level bits the battery's reports mean anything for (0x1004 getCapabilities), read once.
        var batteryLevels: UInt8?
        /// The battery is read from legacy 0x1000, the mouse lacking 0x1004; chosen by `apply`.
        var legacyBatterySelected = false
        var hasSmartShift = false
        var hasThumbWheel = false
    }

    /// What a session hands to the one replacing it on reload: its `DeviceState`, and what the
    /// device may still have diverted.
    struct Inherited {
        var state = DeviceState()
        var diverted: Set<UInt16> = []
        var wheelsMayBeDiverted = false
        /// Not handed down by `inheritance`: the daemon sets it, so a session starts handed back
        /// while the pointer is on another Mac.
        var away = false
        /// The replaced session's `diversionEnd`, set by the daemon: this session's diversion
        /// changes wait for it, so none of the old session's writes can land after them.
        var diversionAfter: Task<Void, Never>?
    }

    init(device: HIDPPDevice, name: String, id: String, controls: [ReprogControls.Control], config: Config,
         inheriting inherited: Inherited = Inherited()) {
        self.device = device
        self.name = name
        self.id = id
        self.config = config
        let controls = Dictionary(controls.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        self.controls = controls
        pressable = controls.values.filter { $0.isDivertable && !$0.isVirtual }.map(\.cid).sorted()
            .map { Status.Device.Control(cid: $0, name: Config.Button(cid: $0)?.rawValue) }
        let global = config.global
        self.global = global
        let scopes = [global] + Array(config.apps.values)
        var bound: [UInt16: Bool] = [:]
        for scope in scopes {
            for (cid, binding) in scope.bindings where controls[cid]?.isDivertable == true {
                let isGesture = if case .gesture = binding { true } else { false }
                bound[cid] = (bound[cid] ?? false) || (isGesture && controls[cid]?.supportsRawXY == true)
            }
        }
        self.bound = bound
        appButtons = config.apps.values.reduce(into: []) { $0.formUnion($1.buttons) }
        appThumbWheel = config.apps.values.contains { $0.setsThumbWheel }
        globalProfile = Self.profile(global, config)
        appProfiles = config.apps.filter { $0.value.setsSmoothScroll }.mapValues { Self.profile($0, config) }
        thumbSettings = global.thumbWheel
        releasing = inherited.diverted.subtracting(bound.keys)
        state = inherited.state
        // The wheels come to PureMouse when any scope scrolls smoothly; the thumb wheel alone
        // when any scope gives it actions. Either way scrolling then runs here.
        smoothAnywhere = scopes.contains { $0.smoothScroll?.enabled == true }
        let thumbActions = scopes.contains { $0.thumbWheel.mode != .scroll }
        scroll = smoothAnywhere || thumbActions ? ScrollEngine(profile: globalProfile) : nil
        away = inherited.away
        diversion = SerialChain(after: inherited.diversionAfter)
        self.wheelsMayBeDiverted = inherited.wheelsMayBeDiverted || scroll != nil
        recognizer = GestureRecognizer(
            threshold: GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: config.dpi ?? 1000),
            repeatInterval: .milliseconds(config.gesture.repeatIntervalMs))
        device.onEvent = { [weak self] in self?.handle($0) }
        if !appProfiles.isEmpty {
            scroll?.profileForBurst = { [weak self] in self?.profileUnderPointer() ?? ScrollEngine.Profile() }
        }
        for cid in config.boundControls.sorted() where controls[cid]?.isDivertable != true {
            Log.error("\(name): control 0x\(String(cid, radix: 16)) is missing or not divertable; skipped")
        }
    }

    /// Controls this session diverts or still owes a release, for handing to its replacement.
    var divertedControls: Set<UInt16> { releasing.union(bound.keys).union(capturing ?? []) }

    var inheritance: Inherited {
        Inherited(state: state, diverted: divertedControls, wheelsMayBeDiverted: wheelsMayBeDiverted)
    }

    var status: Status.Device {
        Status.Device(
            id: id, name: name, connection: device.interface.isReceiver ? .receiver : .bluetooth,
            online: state.online, battery: state.battery.flatMap(Self.status), dpi: state.dpi,
            dpiSteps: state.resolutions?.values ?? [],
            wheelMode: state.wheelMode.map { $0 == .ratchet ? .ratchet : .freespin },
            hasSmartShift: state.hasSmartShift, hasThumbWheel: state.hasThumbWheel,
            controls: pressable)
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

    func changed() {
        onChange?()
    }

    /// Ends once every diversion change asked for so far has; see `Inherited.diversionAfter`.
    var diversionEnd: Task<Void, Never>? { diversion.end }

    func close() {
        finish()
        device.onEvent = nil
    }

    /// Marks the session finished and stops everything under way: each write checks `finished`
    /// before it goes out, and a cancelled request fails at once, so nothing queued reaches the
    /// device after a replacement's writes or `restore`'s.
    private func finish() {
        finished = true
        configuring?.cancel()
        deviceActions.cancel()
        diversion.cancel()
        scroll?.stop()
        dropHeld()
    }

    /// Errors after which no further step is tried: the session finished or the work was cancelled.
    func stops(_ error: Error) -> Bool {
        finished || error is CancellationError
    }

    /// Throws once the session is finished: checked before each write, since a session can finish
    /// while an earlier request is awaited.
    func ensureOpen() throws {
        guard !finished else { throw HIDPPError.closed }
    }

    /// Queues `body` on `chain` (`diversion` or `deviceActions`) and waits for it; cancelling the
    /// caller cancels the body.
    private func serialised(on chain: SerialChain, _ body: @escaping (Session) async throws -> Void) async throws {
        try ensureOpen()
        let work = chain.enqueue { try await body(self) }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// A scope's scrolling. Where it does not scroll smoothly but the wheels are PureMouse's
    /// anyway (another app does, or the thumb wheel has actions), it scrolls without the glide.
    private static func profile(_ settings: Config.AppSettings, _ config: Config) -> ScrollEngine.Profile {
        let s = settings.smoothScroll ?? Config.SmoothScroll()
        let smooth = settings.smoothScroll?.enabled == true
        return ScrollEngine.Profile(speed: s.speed, horizontalSpeed: s.horizontalSpeed, acceleration: s.acceleration,
                                    smoothing: smooth ? .milliseconds(s.smoothingMs) : .zero,
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
        dropHeld()
        configuring = Task {
            try? await Task.sleep(for: delay)
            for attempt in 1...3 {
                guard !Task.isCancelled else { return }
                do {
                    try await apply()
                    // Cached indices only: diagnostics must never add adoption traffic or timeouts.
                    let features = (1...255).compactMap { device.feature(at: UInt8($0)) }.sorted()
                        .map { String(format: "%04x", $0) }
                    Log.info("\(name): configured; features(PureMouse)=\(features.joined(separator: " "))")
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
            guard !Task.isCancelled, !finished, state.online else { return }
            state.online = false
            changed()
        }
    }

    private func apply() async throws {
        // Resolve the event-bearing features first so their events can be routed.
        _ = try await device.hasFeature(ReprogControls.id)
        _ = try? await device.featureIndex(of: WirelessDeviceStatus.id)
        // Select and resolve the battery event source before any configuration writes.
        // Keep the previous selection if an informational lookup fails during reconnect.
        do {
            if try await device.hasFeature(UnifiedBattery.id) {
                state.legacyBatterySelected = false
            } else {
                state.legacyBatterySelected = try await device.hasFeature(LegacyBattery.id)
            }
        } catch { }

        // One step in the chain, so a handoff (`setAway`) cannot interleave with it.
        try await serialised(on: diversion) { try await $0.applyInputs(wheels: true) }
        // Likewise with device actions: a `cycleDPI` mid-apply is neither undone nor overwritten.
        try await serialised(on: deviceActions) { session in
            if try await session.device.hasFeature(AdjustableDPI.id) { try await session.applyDPI() }
            try await session.applyScrollMode()
        }
        await readBattery()
        state.online = true
        changed()
    }

    /// Unsupported or malformed optional-feature replies can be skipped. Transport failures
    /// and cancellation must reach the configure retry/lifecycle handling.
    static func isOptionalFeatureReplyError(_ error: any Error) -> Bool {
        guard let error = error as? HIDPPError else { return false }
        switch error {
        case .malformedResponse, .featureNotSupported, .protocol10, .protocol20: return true
        case .timeout, .closed, .sendFailed: return false
        }
    }

    /// Battery state is informational, read from the source `apply` selected: 0x1004, or legacy
    /// 0x1000 only in its absence.
    private func readBattery() async {
        do {
            try ensureOpen()
            if state.legacyBatterySelected {
                state.battery = try await LegacyBattery.status(device)
            } else if try await device.hasFeature(UnifiedBattery.id) {
                if state.batteryLevels == nil { state.batteryLevels = try await UnifiedBattery.levels(device) }
                try ensureOpen()
                state.battery = try await UnifiedBattery.status(device, levels: state.batteryLevels ?? UnifiedBattery.allLevels)
            }
        } catch {
            if !stops(error) { Log.debug("\(name): reading battery failed: \(error)") }
        }
    }

    /// Sets the DPI wanted now (`liveDPI`, else the config's, if any), snapped to the sensor's
    /// list, and reads back the one in effect. Runs on `deviceActions`.
    func applyDPI() async throws {
        try await readResolutions()
        if let target = state.liveDPI ?? config.dpi {
            try ensureOpen()
            try await AdjustableDPI.set(device, dpi: supportedDPI(near: target))
        }
        try await readDPI()
    }

    /// The wheel's clutch: SmartShift 0x2110 whenever present (the tested path), else Enhanced 0x2111.
    enum Clutch { case smartShift, enhanced }

    /// Which clutch the mouse has, if any. Enhanced-only mice are untested: a malformed or
    /// feature-error reply to its lookup counts as none, but timeouts and transport failures throw.
    func clutch() async throws -> Clutch? {
        if try await device.hasFeature(SmartShift.id) { return .smartShift }
        do {
            return try await device.hasFeature(SmartShiftEnhanced.id) ? .enhanced : nil
        } catch where Self.isOptionalFeatureReplyError(error) {
            Log.error("\(name): SmartShift Enhanced failed (untested mouse): \(error)")
            return nil
        }
    }

    func scrollMode(of clutch: Clutch) async throws -> SmartShift.Mode {
        switch clutch {
        case .smartShift: return try await SmartShift.get(device).mode
        case .enhanced: return try await SmartShiftEnhanced.getRatchetControlMode(device).mode
        }
    }

    /// Nil `autoDisengage` leaves the threshold unchanged; Enhanced writes always carry the mode
    /// and leave torque unchanged.
    func setScrollMode(_ clutch: Clutch, _ mode: SmartShift.Mode, autoDisengage: UInt8? = nil) async throws {
        try ensureOpen()
        switch clutch {
        case .smartShift: try await SmartShift.set(device, mode: mode, autoDisengage: autoDisengage)
        case .enhanced: try await SmartShiftEnhanced.setRatchetControlMode(device, mode: mode, autoDisengage: autoDisengage)
        }
    }

    /// Sets the last toggled (else the configured) scroll mode and threshold, if either is given,
    /// and reads the mode in effect. On an Enhanced-only mouse, malformed or feature-error replies
    /// are skipped; timeouts and transport failures reach configure's retry. Runs on `deviceActions`.
    private func applyScrollMode() async throws {
        var enhanced = false
        do {
            let clutch = try await clutch()
            state.hasSmartShift = clutch != nil
            guard let clutch else { return }
            enhanced = clutch == .enhanced
            let mode = state.scrollMode ?? config.scrollWheel?.mode?.smartShift
            let threshold = config.scrollWheel?.smartShiftThreshold
            let current = try await scrollMode(of: clutch)
            if mode != nil || threshold != nil {
                try await setScrollMode(clutch, mode ?? current, autoDisengage: threshold)
            }
            state.wheelMode = mode ?? current
        } catch where enhanced && Self.isOptionalFeatureReplyError(error) {
            Log.error("\(name): SmartShift Enhanced failed (untested mouse): \(error)")
        }
    }

    /// Reads the resolution in effect, for the status and the gesture distance, which is
    /// physical and so scales with it.
    func readDPI() async throws {
        let current = try await AdjustableDPI.get(device)
        state.dpi = current
        recognizer.threshold = GestureRecognizer.counts(millimetres: config.gesture.distanceMm, dpi: current)
    }

    /// Reads the sensor's supported resolutions once per mouse. A failure is logged and retried
    /// on the next apply; meanwhile DPI targets are sent unchanged.
    private func readResolutions() async throws {
        guard state.resolutions == nil else { return }
        do {
            state.resolutions = try await AdjustableDPI.resolutions(device)
        } catch let error as CancellationError {
            throw error
        } catch HIDPPError.closed {
            throw HIDPPError.closed
        } catch {
            Log.error("\(name): reading supported DPI failed: \(error); DPI is set as configured")
        }
    }

    /// `target` snapped to a resolution the sensor accepts, or unchanged if the list is unknown.
    func supportedDPI(near target: Int) -> Int {
        let dpi = state.resolutions?.nearest(to: target) ?? target
        if dpi != target, snapLogged.insert(target).inserted {
            Log.info("\(name): dpi \(target) is not supported; using \(dpi)")
        }
        return dpi
    }

    /// Each request `restore` makes waits this long at most, so one the mouse misses still leaves
    /// time for every other before the daemon's deadline (`Daemon.shutdownDeadline`).
    static let restoreTimeout: Duration = .milliseconds(400)

    /// The hand-backs `restore` makes, each one request when feature indices are cached.
    var restoreSteps: Int { (wheelsMayBeDiverted ? 2 : 0) + divertedControls.count }

    /// Hands the mouse back in its native state: buttons undiverted and wheels reporting as
    /// ordinary HID scrolling, so it works without PureMouse. Used when PureMouse quits or pauses.
    func restore() async {
        finish()
        // Cancelled work stops at its next write, and its request in flight fails at once.
        await diversion.drain()
        await deviceActions.drain()
        let timeout = device.timeout
        device.timeout = Self.restoreTimeout
        defer { device.timeout = timeout }
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
}
