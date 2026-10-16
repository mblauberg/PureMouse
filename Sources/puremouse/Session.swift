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
    private let pressable: [Status.Device.Control]
    /// Called after anything in `status` may have changed.
    var onChange: (() -> Void)?
    /// Called with the first control pressed while capturing; that press performs nothing.
    var onCapture: ((UInt16) -> Void)?
    private let config: Config
    /// What applies where no app entry matches.
    private let global: Config.AppSettings
    /// Controls bound globally or in any app, all diverted; true for those diverted with raw
    /// motion because some scope binds them to a gesture.
    private let bound: [UInt16: Bool]
    /// Whether any app sets buttons, thumb wheel or smooth scrolling: only then is the app
    /// looked up, at a press, a thumb-wheel movement or a scroll burst.
    private let appButtons: Bool
    private let appThumbWheel: Bool
    /// Smooth scrolling profiles of the apps that set it, by lowercased bundle ID.
    private let appProfiles: [String: ScrollEngine.Profile]
    private let globalProfile: ScrollEngine.Profile
    /// Controls a previous session diverted that this one no longer binds; released on apply.
    private var releasing: Set<UInt16>
    private let scroll: ScrollEngine?
    /// Whether any scope scrolls smoothly, so the main wheel is diverted too.
    private let smoothAnywhere: Bool
    /// Whether the wheels may be diverted to PureMouse, by this session or one it replaced, so
    /// `restore` must hand them back even if this session's config never diverts them.
    private(set) var wheelsMayBeDiverted: Bool

    /// Last scroll mode set by toggling; survives reconnects, overriding the configured mode.
    private var scrollMode: SmartShift.Mode?
    /// Buttons down, the gesture held and native clicks posted (`HeldButtons`).
    private var held = HeldButtons()
    /// The thumb wheel settings of the current movement and its step counter.
    private var thumbSettings = Config.ThumbWheel()
    private var thumbStepper = ThumbStepper(threshold: 1)
    private var thumbLast: ContinuousClock.Instant?
    /// A pause this long ends a thumb-wheel movement, like the wheel's own stop report.
    private static let thumbGap: Duration = .milliseconds(500)
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
    /// Level bits the battery's reports mean anything for (0x1004 getCapabilities), read once.
    private var batteryLevels: UInt8?
    private var hasSmartShift: Bool
    private var hasThumbWheel: Bool
    private var configuring: Task<Void, Never>?
    /// Device actions (toggle scroll mode, cycle DPI), chained so quick presses apply in order.
    private var deviceAction: Task<Void, Never>?
    /// Controls diverted only so select-by-pressing can see them; nil when not capturing.
    private var capturing: Set<UInt16>?
    /// Every change to which controls are diverted, by configuration or capture, chained so each
    /// runs alone and they reach the device in the order they were asked for.
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
        var batteryLevels: UInt8?
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
        appButtons = config.apps.values.contains { $0.setsButtons }
        appThumbWheel = config.apps.values.contains { $0.setsThumbWheel }
        globalProfile = Self.profile(global, config)
        appProfiles = config.apps.filter { $0.value.setsSmoothScroll }.mapValues { Self.profile($0, config) }
        thumbSettings = global.thumbWheel
        releasing = inherited.diverted.subtracting(bound.keys)
        scrollMode = inherited.scrollMode
        liveDPI = inherited.liveDPI
        resolutions = inherited.resolutions
        online = inherited.online
        dpi = inherited.dpi
        wheelMode = inherited.wheelMode
        battery = inherited.battery
        batteryLevels = inherited.batteryLevels
        hasSmartShift = inherited.hasSmartShift
        hasThumbWheel = inherited.hasThumbWheel
        // The wheels come to PureMouse when any scope scrolls smoothly; the thumb wheel alone
        // when any scope gives it actions. Either way scrolling then runs here.
        smoothAnywhere = scopes.contains { $0.smoothScroll?.enabled == true }
        let thumbActions = scopes.contains { $0.thumbWheel.mode != .scroll }
        scroll = smoothAnywhere || thumbActions ? ScrollEngine(profile: globalProfile) : nil
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
        Inherited(diverted: divertedControls, wheelsMayBeDiverted: wheelsMayBeDiverted, scrollMode: scrollMode,
                  liveDPI: liveDPI,
                  resolutions: resolutions, online: online, dpi: dpi, wheelMode: wheelMode,
                  battery: battery, batteryLevels: batteryLevels, hasSmartShift: hasSmartShift, hasThumbWheel: hasThumbWheel)
    }

    var status: Status.Device {
        Status.Device(
            id: id, name: name, connection: device.interface.isReceiver ? .receiver : .bluetooth,
            online: online, battery: battery.flatMap(Self.status), dpi: dpi, dpiSteps: resolutions?.values ?? [],
            wheelMode: wheelMode.map { $0 == .ratchet ? .ratchet : .freespin },
            hasSmartShift: hasSmartShift, hasThumbWheel: hasThumbWheel,
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

    private func changed() {
        onChange?()
    }

    func close() {
        finished = true
        configuring?.cancel()
        deviceAction?.cancel()
        scroll?.stop()
        dropHeld()
        device.onEvent = nil
    }

    // MARK: Select by pressing

    /// Diverts every pressable control not already bound, so the next press of any control
    /// reaches `onCapture` instead of macOS or an action.
    func beginCapture() {
        guard !finished, capturing == nil else { return }
        let extras = Set(pressable.map(\.cid)).subtracting(bound.keys)
        capturing = extras
        releasing.subtract(extras)
        // A gesture held as capture starts must not act when it is let go.
        held.forgetGesture()
        enqueueDiversion { session in
            for cid in extras where session.capturing != nil {
                try await session.setDiverted(cid, true)
            }
        }
    }

    /// Hands the controls diverted for capture back to macOS.
    func endCapture() {
        guard let extras = capturing else { return }
        capturing = nil
        releasing.formUnion(extras)
        enqueueDiversion { try await $0.releaseAll() }
    }

    /// Releases every control in `releasing`, each independently: one that fails stays there
    /// for the next apply (or `restore`) to retry. Throws the last failure.
    private func releaseAll() async throws {
        var failure: Error?
        for cid in releasing {
            do {
                try await setDiverted(cid, false)
                releasing.remove(cid)
            } catch {
                guard !finished, !(error is CancellationError) else { throw error }
                Log.debug("\(name): releasing 0x\(String(cid, radix: 16)) failed: \(error)")
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// A diversion write on this session's behalf; refused once the session is finished.
    private func setDiverted(_ cid: UInt16, _ divert: Bool, rawXY: Bool = false) async throws {
        guard !finished else { throw HIDPPError.closed }
        try await ReprogControls.setDiverted(device, cid: cid, divert: divert, rawXY: rawXY)
    }

    /// Queues `body` to run after every diversion change asked for before it and before any
    /// asked for after. Diversion state is read when the body runs, so a later change (say
    /// capture ending mid-apply) is made by its own body afterwards rather than raced.
    @discardableResult
    private func enqueueDiversion(_ body: @escaping (Session) async throws -> Void) -> Task<Void, Error> {
        let work = Task { [previous = diverting] in
            await previous?.value
            try await body(self)
        }
        diverting = Task {
            if case .failure(let error) = await work.result, !finished {
                // Usually asleep: the next apply diverts or releases them.
                Log.debug("\(name): diversion change failed: \(error)")
            }
        }
        return work
    }

    /// `enqueueDiversion`, waiting for the body; cancelling the caller cancels the body.
    private func serialised(_ body: @escaping (Session) async throws -> Void) async throws {
        guard !finished else { throw HIDPPError.closed }
        let work = enqueueDiversion(body)
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Lets every diversion change already asked for finish (each stops at its next write once
    /// `finished` is set).
    private func drainDiversion() async {
        await diverting?.value
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

    private func profileUnderPointer() -> ScrollEngine.Profile {
        guard let app = ForegroundApp.shared.underPointer(), let profile = appProfiles[app.lowercased()] else {
            return globalProfile
        }
        Log.debug("\(name): scrolling with \(app)'s settings")
        return profile
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

        try await serialised { session in
            try await session.releaseAll()
            for (cid, rawXY) in session.bound {
                try await session.setDiverted(cid, true, rawXY: rawXY)
            }
            for cid in session.capturing ?? [] {
                try await session.setDiverted(cid, true)
            }
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
            if batteryLevels == nil { batteryLevels = try await UnifiedBattery.levels(device) }
            battery = try await UnifiedBattery.status(device, levels: batteryLevels ?? UnifiedBattery.allLevels)
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
    /// handled in software; thumb-wheel actions take the thumb wheel alone. Otherwise they report
    /// as ordinary HID scrolling (Logi Options+ leaves them diverted, which would leave them dead
    /// without it), inverted in hardware.
    private func applyWheels() async throws {
        // Taking the wheels over without permission to post scroll events would silence them.
        let takeOver = scroll != nil && Permissions.current.contains(.accessibility)
        if scroll != nil && !takeOver { Log.error("\(name): no Accessibility permission; leaving the wheels native") }
        let smooth = takeOver && smoothAnywhere
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
            if takeOver {
                thumbInfo = try await ThumbWheel.info(device)
            } else if let configured = config.thumbWheel?.inverted {
                inverted = configured
            } else {
                inverted = try await ThumbWheel.reporting(device).inverted
            }
            try await ThumbWheel.setReporting(device, .init(diverted: takeOver, inverted: inverted))
        }
        if !takeOver { wheelsMayBeDiverted = false }
    }

    /// Hands the mouse back in its native state: buttons undiverted and wheels reporting as
    /// ordinary HID scrolling, so it works without PureMouse. Used when PureMouse quits.
    func restore() async {
        finished = true
        configuring?.cancel()
        deviceAction?.cancel()
        scroll?.stop()
        dropHeld()
        await drainDiversion()
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
                // The mouse is off or out of range: its releases will not arrive.
                scroll?.stop()
                dropHeld()
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
            if let event = ThumbWheel.parse(function: report.function, params: report.params) { thumbMoved(event) }
        case ReprogControls.id:
            switch ReprogControls.parse(function: report.function, params: report.params) {
            case .buttons(let cids): buttonsChanged(cids)
            case .rawXY(let dx, let dy): moved(dx: Int(dx), dy: Int(dy))
            case nil: break
            }
        case UnifiedBattery.id:
            if let state = UnifiedBattery.parse(function: report.function, params: report.params,
                                                 levels: batteryLevels ?? UnifiedBattery.allLevels),
               state != battery {
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
        let (pressed, released) = held.update(cids)
        released.forEach(release)
        if capturing != nil {
            if let first = pressed.first { onCapture?(first) }
            return
        }
        pressed.forEach(press)
    }

    /// Thumb-wheel rotation: scrolling, or actions counted out in steps. Which, and the app it
    /// is for (the one under the pointer), is settled when a movement starts.
    private func thumbMoved(_ event: ThumbWheel.Event) {
        let now = ContinuousClock.now
        if event.status == .start || thumbLast.map({ now - $0 >= Self.thumbGap }) ?? true {
            beginThumbMovement()
        }
        thumbLast = now
        guard event.rotation != 0 else { return }
        switch thumbSettings.mode {
        case .scroll:
            scroll?.thumb(event.rotation, perRotation: thumbInfo.divertedResolution,
                          nativeSteps: thumbInfo.nativeResolution)
        case .actions(let left, let right):
            // Raw positive rotation scrolls left with natural scrolling off; actions ignore that
            // setting but follow `inverted`.
            let units = config.thumbWheel?.inverted == true ? -event.rotation : event.rotation
            let steps = thumbStepper.add(units, at: now)
            for _ in 0..<abs(steps) { perform(steps > 0 ? left : right) }
        }
    }

    private func beginThumbMovement() {
        var settings = global.thumbWheel
        if appThumbWheel, let app = ForegroundApp.shared.underPointer(), let scoped = config.settings(forApp: app) {
            settings = scoped.thumbWheel
            Log.debug("\(name): thumb wheel with \(app)'s settings")
        }
        thumbSettings = settings
        thumbStepper.reset()
        if case .actions(let left, let right) = settings.mode {
            thumbStepper.threshold = ThumbStepper.threshold(step: settings.step, native: thumbInfo.nativeResolution,
                                                            diverted: thumbInfo.divertedResolution)
            thumbStepper.pacing = ThumbStepper.pacing(left: left, right: right)
        }
    }

    /// The binding for a press: the frontmost app's when an app entry names it, else the global one.
    private func binding(for cid: UInt16) -> Config.Binding? {
        if appButtons, let app = ForegroundApp.shared.frontmost(), let scoped = config.settings(forApp: app) {
            Log.debug("\(name): buttons with \(app)'s settings")
            return scoped.bindings[cid]
        }
        return global.bindings[cid]
    }

    private func press(_ cid: UInt16) {
        Log.debug("\(name): press 0x\(String(cid, radix: 16))")
        switch binding(for: cid) {
        case .action(let action):
            perform(action)
        case .gesture(let gesture):
            guard held.holdGesture(cid, gesture) else { return }
            recognizer.begin()
        case nil:
            // Bound only in other apps: click as the mouse would without PureMouse.
            held.clickNatively(cid)
        }
    }

    private func release(_ cid: UInt16) {
        guard let gesture = held.release(cid) else { return }
        if recognizer.end() { perform(gesture.click) }
    }

    /// Lets go of every held button without acting on it, posting the releases of native clicks,
    /// and ends any thumb-wheel movement: for when the mouse's own releases may never come.
    private func dropHeld() {
        held.drop()
        thumbLast = nil
    }

    private func moved(dx: Int, dy: Int) {
        guard let gesture = held.gesture?.gesture,
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

    /// Drops the DPI chosen by `cycleDPI` and sets the config's, after any pending device action.
    /// The override goes at once, so a session replacing this one before the write runs inherits
    /// none and applies the config's itself; a `cycleDPI` queued earlier cannot bring it back.
    func useConfiguredDPI() {
        guard !finished else { return }
        liveDPI = nil
        deviceAction = Task { [previous = deviceAction] in
            await previous?.value
            liveDPI = nil
            guard !finished else { return }
            do {
                if let target = config.dpi, try await device.hasFeature(AdjustableDPI.id), !finished {
                    try await AdjustableDPI.set(device, dpi: supportedDPI(near: target))
                    try await readDPI()
                }
            } catch {
                Log.error("\(name): setting DPI failed: \(error)")
            }
            changed()
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
