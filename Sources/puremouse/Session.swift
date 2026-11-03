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
    /// Read once at adoption and kept by replacement sessions; reported in `status`.
    let identity: Identification
    /// The device key: which `devices` entry of the config applies (`Config.forDevice`).
    var deviceKey: String? { identity.deviceKey }
    var unit: String? { identity.unit }
    var kind: DeviceName.Kind? { identity.kind }
    /// Reported in `Status.Device.id`: stable while the daemon runs.
    let id: String
    let controls: [UInt16: ReprogControls.Control]
    /// Controls a user can press (divertable, not virtual), by CID, as reported in `status`.
    let pressable: [Status.Device.Control]
    /// Called after anything in `status` may have changed.
    var onChange: (() -> Void)?
    /// Called with the first control pressed while capturing; that press performs nothing.
    var onCapture: ((UInt16) -> Void)?
    /// Called with each connection notification before the session acts on it; true when the daemon
    /// dealt with it (it replaced this session, or is quitting or paused), so the session does not.
    var onConnection: ((Report) -> Bool)?
    /// Called after a configure succeeds while the identity is `unresolved`: the daemon reads it
    /// again, and replaces this session with one keyed by the answer. Once per configure.
    var resolveIdentity: ((Session) async -> Void)?
    let config: Config
    let environment: SessionEnvironment
    /// What applies where no app entry matches.
    let global: Config.AppSettings
    /// Controls bound globally or in any app, all diverted; true for those diverted with raw
    /// motion because some scope binds them to a gesture.
    let bound: [UInt16: Bool]
    /// Controls left native because every binding of theirs posts events and PureMouse cannot
    /// (no Accessibility); the next process, started when it is granted, diverts them.
    let needsAccessibility: Set<UInt16>
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
    var needsDiversionScan: Bool
    /// Another program's persistent settings are never changed, including during capture/restore.
    var persistentControls: Set<UInt16>
    let scroll: ScrollEngine?
    /// Whether any scope scrolls smoothly, so the main wheel is diverted too.
    let smoothAnywhere: Bool
    /// Whether the wheels may be diverted to PureMouse, by this session or one it replaced, so
    /// `restore` must hand them back even if this session's config never diverts them.
    var wheelsMayBeDiverted: Bool
    /// The notched wheel did not report diverted when asked, so it scrolls natively and smooth
    /// scrolling is not offered; not asked again by this session.
    var notchedRefused = false

    /// Buttons down, the gesture held and native clicks posted (`HeldButtons`).
    var held: HeldButtons
    /// Each bound control's press plan where no app entry matches, and by lowercased bundle ID for
    /// the apps that set buttons, compiled here so a press only looks one up.
    let globalPlans: [UInt16: PressPlan]
    let appPlans: [String: [UInt16: PressPlan]]
    /// The presses under way that wait on a trigger, by control (`Session+Input`).
    var presses: [UInt16: Press] = [:]
    /// The control whose press has Precise Pointer slowing the pointer, until it is let go.
    var precise: UInt16?
    /// Controls pressed now whose raw pointer motion is off for the press (`setPointerFree`).
    var pointerFree: Set<UInt16> = []
    /// The thumb wheel settings of the current movement and its step counter.
    var thumbSettings = Config.ThumbWheel()
    var thumbStepper = ThumbStepper(threshold: 1)
    var thumbLast: ContinuousClock.Instant?
    /// A pause this long ends a thumb-wheel movement, like the wheel's own stop report.
    static let thumbGap: Duration = .milliseconds(500)
    var recognizer: GestureRecognizer
    var wheelMultiplier = 15
    var thumbInfo = ThumbWheel.Info(nativeResolution: 18, divertedResolution: 120)
    /// Device state that outlives a config (see `DeviceState`).
    var state: DeviceState
    var hapticCapabilities: Haptic.Capabilities?
    /// What reports the battery, in the order `apply` prefers them.
    enum BatterySource { case unified, legacy, voltage }

    /// Something the mouse lacks for the config, said once per session (`notice`); a replacement
    /// session says it again. A snapped DPI is once per mouse instead (`DeviceState.snapLogged`).
    enum Notice: Hashable { case hapticMissing, smoothScrollUnsupported, toggleUnsupported }
    var noticed: Set<Notice> = []
    /// The capabilities last published in `status`, so a lookup resolving after apply can
    /// publish its answer (`capabilitiesMayHaveChanged`).
    private var publishedCapabilities: Status.Device.Capabilities?
    var unsupportedHaptics: Set<HapticWaveform> = []
    private var configuring: Task<Void, Never>?
    private var configureGeneration = 0
    var isConfiguring: Bool { configuring != nil }
    private var lastConfigureEnded: ContinuousClock.Instant?
    /// The receiver said this mouse's link is down and has not said it is up since: the mouse is
    /// off or on another computer, so waking the Mac has nothing to apply to.
    var linkDown = false
    /// Attempts begun by every configure of this session, so a test can count them rather than
    /// time them.
    private(set) var attemptsMade = 0
    /// Called as each attempt begins, with the count so far: tests decide what the fake mouse does
    /// by the attempt, not by watching the clock.
    var attemptStarting: (@MainActor (Int) -> Void)?
    private var replyObserver: Int?
    static let offlineReconfigureGap: Duration = .seconds(30)
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
        /// The pointer speed Precise Pointer slowed from, while the slower one may be on the mouse:
        /// set by the write that slows it, cleared by the one that puts the speed in effect back
        /// (`restorePointerSpeed`, `applyDPI`, `restore`). Handed to a replacement, so a reload
        /// mid-hold still restores it.
        var preciseFrom: Int?
        /// The feature DPI is set through, found once per mouse (`dpiFeature`).
        var dpiFeature: DPIFeature?
        /// The sensor's supported resolutions, read once per mouse.
        var resolutions: AdjustableDPI.Resolutions?
        /// The mouse read back another resolution than the one written, as an onboard profile may
        /// leave it (0x8100, never written), so PureMouse no longer sets its DPI.
        var dpiRefused = false
        var online = true
        var dpi: Int?
        var wheelMode: SmartShift.Mode?
        var battery: UnifiedBattery.State?
        /// Level bits the battery's reports mean anything for (0x1004 getCapabilities), read once.
        var batteryLevels: UInt8?
        /// Where the battery is read from, chosen by `apply`: 0x1004, else 0x1000, else 0x1001.
        var batterySource: BatterySource?
        /// An apply has succeeded, so feature lookups have been made and `capabilities` can be
        /// reported from them.
        var applied = false
        /// Whether the settings are on the mouse now (`Status.Device.applied`); nil until a
        /// configure first starts. Moves only on a configure starting, ending or failing.
        var appliedStatus: Status.Device.Applied? {
            didSet { if appliedStatus?.state != .applying { settledApplied = appliedStatus } }
        }
        /// The last applied state that is not the transient `applying`: what a superseded configure
        /// goes back to, and what a replacement session inherits in its place.
        var settledApplied: Status.Device.Applied?
        /// The main firmware, read once per mouse (`readFacts`).
        var firmware: String?
        /// The firmware has been asked for and answered, with a version or without one.
        var firmwareRead = false
        /// The Easy-Switch hosts, read after each successful configure.
        var hosts: Status.Device.Hosts?
        /// Targets already reported as snapped to a supported resolution, so each is logged once
        /// per mouse: kept, like the rest of `DeviceState`, by the sessions replacing this one.
        var snapLogged: Set<Int> = []
    }

    /// What a session hands to the one replacing it on reload: its `DeviceState`, and what the
    /// device may still have diverted.
    struct Inherited {
        var state = DeviceState()
        var diverted: Set<UInt16> = []
        var persistentControls: Set<UInt16> = []
        var wheelsMayBeDiverted = false
        /// Only a newly adopted endpoint needs to discover a previous process's diversions.
        var fresh = false
        /// Not handed down by `inheritance`: the daemon sets it, so a session starts handed back
        /// while the pointer is on another Mac.
        var away = false
        /// The replaced session's `diversionEnd`, set by the daemon: this session's diversion
        /// changes wait for it, so none of the old session's writes can land after them.
        var diversionAfter: Task<Void, Never>?
    }

    init(device: HIDPPDevice, name: String, identity: Identification, id: String,
         controls: [ReprogControls.Control], config: Config,
         inheriting inherited: Inherited = Inherited(), environment: SessionEnvironment = .live) {
        self.device = device
        self.name = name
        self.identity = identity
        self.id = id
        self.config = config
        self.environment = environment
        let controls = Dictionary(controls.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        self.controls = controls
        pressable = controls.values.filter { Self.isDivertable($0.cid, in: controls) && !$0.isVirtual }
            .map(\.cid).sorted()
            .map { Status.Device.Control(cid: $0, name: Config.Button(cid: $0)?.rawValue,
                                         gestures: controls[$0]?.supportsRawXY) }
        let global = config.global
        self.global = global
        let scopes = [global] + Array(config.apps.values)
        var bound: [UInt16: Bool] = [:]
        // A binding that cannot be performed without permission to post events leaves its control
        // native (`Config.Binding.isPerformable`); a control some scope can still act on is diverted.
        var native: Set<UInt16> = []
        for scope in scopes {
            for (cid, binding) in scope.bindings where Self.isDivertable(cid, in: controls) {
                guard binding.isPerformable(canPostEvents: environment.canPostEvents) else {
                    native.insert(cid)
                    continue
                }
                let moves = PressPlan(binding).moves
                bound[cid] = (bound[cid] ?? false) || (moves && controls[cid]?.supportsRawXY == true)
            }
        }
        self.bound = bound
        needsAccessibility = native.subtracting(bound.keys)
        appButtons = config.apps.values.reduce(into: []) { $0.formUnion($1.buttons) }
        globalPlans = global.bindings.mapValues(PressPlan.init)
        appPlans = config.apps.filter { $0.value.setsButtons }.mapValues { $0.bindings.mapValues(PressPlan.init) }
        held = environment.heldButtons()
        appThumbWheel = config.apps.values.contains { $0.setsThumbWheel }
        globalProfile = Self.profile(global, config)
        appProfiles = config.apps.filter { $0.value.setsSmoothScroll }.mapValues { Self.profile($0, config) }
        thumbSettings = global.thumbWheel
        releasing = inherited.diverted.subtracting(bound.keys)
        needsDiversionScan = inherited.fresh
        persistentControls = inherited.persistentControls
        state = inherited.state
        // The wheels come to PureMouse when any scope scrolls smoothly; the thumb wheel alone
        // when any scope gives it actions. Either way scrolling then runs here.
        smoothAnywhere = scopes.contains { $0.smoothScroll?.enabled == true }
        let thumbActions = scopes.contains { $0.thumbWheel.mode != .scroll }
        scroll = smoothAnywhere || thumbActions ? ScrollEngine(profile: globalProfile, clock: environment.frameClock(), post: environment.postScroll,
                                                       naturalScrolling: environment.naturalScrolling) : nil
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
        if !needsAccessibility.isEmpty {
            Log.info("\(name): no Accessibility permission; leaving \(needsAccessibility.sorted().map(ControlNames.describe).joined(separator: ", ")) native")
        }
        // Config is shared by every mouse, so a binding this one cannot take is expected: noted once.
        let unbindable = config.boundControls.sorted().filter { controls[$0]?.isDivertable != true }
        if !unbindable.isEmpty {
            Log.debug("\(name): \(unbindable.map(ControlNames.describe).joined(separator: ", ")) missing or not divertable; skipped")
        }
    }

    /// A control PureMouse may divert: the mouse reports it divertable and it is not a primary
    /// click (`Config.reservedControls`), which always stays native.
    func isDivertable(_ cid: UInt16) -> Bool { Self.isDivertable(cid, in: controls) }

    private static func isDivertable(_ cid: UInt16, in controls: [UInt16: ReprogControls.Control]) -> Bool {
        controls[cid]?.isDivertable == true && !Config.reservedControls.contains(cid)
    }

    /// Whether `error` is the device answering (an error code or a malformed reply) rather than
    /// a timeout, transport failure or cancellation, which must reach configure's retry.
    nonisolated static func isDeviceAnswer(_ error: any Error) -> Bool {
        (error as? HIDPPError)?.isDeviceAnswer == true
    }

    /// Controls this session diverts or still owes a release, for handing to its replacement.
    var divertedControls: Set<UInt16> {
        releasing.union(bound.keys).union(capturing ?? []).subtracting(persistentControls)
    }

    var inheritance: Inherited {
        Inherited(state: state, diverted: divertedControls, persistentControls: persistentControls,
                  wheelsMayBeDiverted: wheelsMayBeDiverted, fresh: needsDiversionScan)
    }

    var status: Status.Device {
        Status.Device(
            id: id, name: name, connection: device.interface.isReceiver ? .receiver : .bluetooth,
            online: state.online, battery: state.battery.flatMap(Self.status), dpi: state.dpi,
            dpiSteps: state.resolutions?.values ?? [],
            wheelMode: state.wheelMode.map { $0 == .ratchet ? .ratchet : .freespin },
            controls: pressable, model: deviceKey, unit: unit, kind: kind?.name, capabilities: capabilities,
            applied: state.appliedStatus, firmware: state.firmware, hosts: state.hosts)
    }

    /// What the mouse has, from the lookups an apply made (`HIDPPDevice.knownPresence`), so
    /// building it sends nothing. Nil before the first successful apply; a member is nil while
    /// unknown, such as after a lookup that timed out. A choice of features is false only when
    /// all are known absent.
    var capabilities: Status.Device.Capabilities? {
        guard state.applied else { return nil }
        func has(_ feature: UInt16) -> Bool? { device.knownPresence(of: feature) }
        return Status.Device.Capabilities(
            dpi: state.dpiRefused ? false : hasAny(of: [AdjustableDPI.id, ExtendedDPI.id]), smartShift: hasAny(of: [SmartShift.id, SmartShiftEnhanced.id]),
            smoothScroll: scrollsSmoothly, thumbWheel: has(ThumbWheel.id), haptics: has(Haptic.id),
            battery: hasAny(of: [UnifiedBattery.id, LegacyBattery.id, BatteryVoltage.id]))
    }

    /// Whether the main wheel can scroll smoothly, from known presence (nil while unknown): it
    /// needs one of the features PureMouse takes the main wheel over through (`Wheel.mainWheels`).
    var scrollsSmoothly: Bool? { notchedRefused ? false : hasAny(of: Wheel.mainWheels.map(\.feature)) }

    /// Publishes `capabilities` when a lookup after apply, such as a haptic action's, has changed
    /// them.
    func capabilitiesMayHaveChanged() {
        if capabilities != publishedCapabilities { changed() }
    }

    private func hasAny(of features: [UInt16]) -> Bool? {
        let presence = features.map { device.knownPresence(of: $0) }
        return presence.contains(true) ? true : presence.allSatisfy { $0 == false } ? false : nil
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
        publishedCapabilities = capabilities
        onChange?()
    }

    /// Logs `message` at info, once per session for each `notice`.
    func notice(_ notice: Notice, _ message: @autoclosure () -> String) {
        if noticed.insert(notice).inserted { Log.info("\(name): \(message())") }
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
    /// answer. Safe to call repeatedly; a newer call supersedes an older one, so a link-up or
    /// reconnect mid-configure is never lost (`reconfigureIfOffline` alone defers to one running).
    func configure(after delay: Duration = .zero) {
        guard !finished else { return }
        configuring?.cancel()
        dropHeld()
        configureGeneration &+= 1
        let generation = configureGeneration
        // A superseded configure's "applying" goes with it: until this one is answered the mouse
        // shows what it showed before that.
        if state.appliedStatus?.state == .applying { setApplied(state.settledApplied) }
        let repliesAtStart = device.repliesReceived
        // "Applying settings…" is for a mouse that is answering: until the first reply it keeps what
        // it showed (Asleep, or its last state), so a silent mouse never flashes it. The
        // registration is this configure's own, so a replacement's (or another session's, after a
        // reload) is never removed by it.
        replyObserver.map { device.stopObserving($0) }
        let observer = device.observeNextReply { [weak self] in
            guard let self, !finished, configureGeneration == generation else { return }
            setApplied(.init(state: .applying))
        }
        replyObserver = observer
        configuring = Task {
            // The short wait lent to this task's requests. Returning it ends only this lend: a
            // replacement's, or a restore's, stands (`HIDPPDevice.returnTimeout`).
            var lease: Int?
            defer {
                if let lease { device.returnTimeout(lease) }
                device.stopObserving(observer)
                // A superseded task ends after its replacement started; leave the replacement's handle.
                if configureGeneration == generation {
                    configuring = nil
                    lastConfigureEnded = environment.now()
                }
            }
            try? await Task.sleep(for: delay)
            for attempt in 1...3 {
                guard !Task.isCancelled else { return }
                attemptsMade += 1
                attemptStarting?(attemptsMade)
                if let timeout = environment.attemptTimeout { lease = device.lendTimeout(timeout) }
                do {
                    try await apply()
                    // Cached indices only: diagnostics must never add adoption traffic or timeouts.
                    let features = (1...255).compactMap { device.feature(at: UInt8($0)) }.sorted()
                        .map { String(format: "%04x", $0) }
                    Log.info("\(name): configured; features(PureMouse)=\(features.joined(separator: " "))")
                    if identity.unresolved, !finished { await resolveIdentity?(self) }
                    await readFacts()
                    return
                } catch is CancellationError {
                    return
                } catch HIDPPError.closed {
                    return
                } catch {
                    Log.error("\(name): configure attempt \(attempt) failed: \(error)")
                }
                // Usually the mouse is asleep; its reconnect event will also trigger a retry.
                try? await Task.sleep(for: environment.configureRetryDelay)
            }
            guard !Task.isCancelled, !finished else { return }
            // Out of attempts. A mouse that answered something and still could not be configured
            // has settings not applied; Apply Settings Again (`reapply`) or its own reconnect
            // starts the next apply. One that never answered, or whose link went down, is asleep
            // or away, not failed: it is offline with nothing said about the settings, and its
            // next link-up or answer starts a configure.
            let answered = device.repliesReceived > repliesAtStart
            state.appliedStatus = answered && !linkDown ? .init(state: .notApplied) : nil
            state.online = false
            changed()
        }
    }

    /// The receiver said the link is down: the mouse is off or on another computer. A configure
    /// under way is over (it would only run out of attempts), and nothing is known of the settings.
    func linkWentDown() {
        linkDown = true
        configuring?.cancel()
        configureGeneration &+= 1
        configuring = nil
        setApplied(nil)
    }

    /// Wake: starts a configure at once, except for a mouse the receiver last said is away, whose
    /// link-up will start one.
    func configureAfterWake() {
        guard !linkDown else { return }
        configure()
    }

    /// Apply Settings Again: a fresh apply, only for a mouse whose settings are not applied, and
    /// not held back by the offline guard.
    func reapply() {
        guard !finished, state.appliedStatus?.state == .notApplied else { return }
        configure()
    }

    /// Records `applied` and publishes it when it differs, so the status moves on transitions only.
    private func setApplied(_ applied: Status.Device.Applied?) {
        guard state.appliedStatus != applied else { return }
        state.appliedStatus = applied
        changed()
    }

    /// Facts for About This Mouse, all reads: the main firmware once per mouse, and the Easy-Switch
    /// hosts after each configure (the mouse may be on another host since). A feature the mouse
    /// lacks leaves its fact out; a read that fails leaves what was known. Nothing is written
    /// (docs/how-it-works.md, "Sessions").
    func readFacts() async {
        var firmware = state.firmware
        var hosts = state.hosts
        do {
            try ensureOpen()
            if !state.firmwareRead {
                if try await device.hasFeature(DeviceIdentity.id) {
                    firmware = try await DeviceIdentity.mainFirmware(device)?.text
                }
                state.firmwareRead = true
            }
            try ensureOpen()
            if try await device.hasFeature(HostsInfo.id) {
                let info = try await HostsInfo.info(device)
                let list = try await HostsInfo.hosts(device, info: info)
                hosts = .init(current: info.current, slots: list.map {
                    .init(name: $0.name.isEmpty ? nil : $0.name, paired: $0.paired)
                })
            } else if try await device.hasFeature(ChangeHost.id) {
                let info = try await ChangeHost.info(device)
                hosts = .init(current: info.current, slots: Array(repeating: .init(), count: info.count))
            }
        } catch {
            if !stops(error) { Log.debug("\(name): reading firmware and hosts failed: \(error)") }
        }
        guard !finished, firmware != state.firmware || hosts != state.hosts else { return }
        state.firmware = firmware
        state.hosts = hosts
        changed()
    }

    /// An offline mouse can return without either reconnect notification. Events drive this
    /// throttle; there is no periodic work while the device is idle.
    func reconfigureIfOffline() {
        guard !finished, !state.online, !isConfiguring,
              lastConfigureEnded.map({ environment.now() - $0 >= Self.offlineReconfigureGap }) ?? true else { return }
        configure()
    }

    func apply() async throws {
        // Resolve the event-bearing features first so their events can be routed.
        _ = try await device.hasFeature(ReprogControls.id)
        _ = try? await device.featureIndex(of: WirelessDeviceStatus.id)
        // Select and resolve the battery event source before any configuration writes.
        // Keep the previous selection if an informational lookup fails during reconnect.
        do {
            if try await device.hasFeature(UnifiedBattery.id) {
                state.batterySource = .unified
            } else if try await device.hasFeature(LegacyBattery.id) {
                state.batterySource = .legacy
            } else {
                state.batterySource = try await device.hasFeature(BatteryVoltage.id) ? .voltage : nil
            }
        } catch { }

        // One step in the chain, so a handoff (`setAway`) cannot interleave with it.
        try await serialised(on: diversion) { try await $0.applyInputs(wheels: true) }
        // Likewise with device actions: a `cycleDPI` mid-apply is neither undone nor overwritten.
        try await serialised(on: deviceActions) { session in
            try await session.applyDPI()
            try await session.applyScrollMode()
        }
        await readBattery()
        // A configure that began meanwhile has superseded this apply; it must not report applied.
        try ensureOpen()
        try Task.checkCancellation()
        state.online = true
        state.applied = true
        state.appliedStatus = .init(state: .applied, at: environment.date())
        changed()
    }

    /// Battery state is informational, read from the source `apply` selected: 0x1004, or legacy
    /// 0x1000, or 0x1001's voltage (a level only), each only in the absence of those before it.
    private func readBattery() async {
        do {
            try ensureOpen()
            switch state.batterySource {
            case .unified:
                if state.batteryLevels == nil { state.batteryLevels = try await UnifiedBattery.levels(device) }
                try ensureOpen()
                state.battery = try await UnifiedBattery.status(device, levels: state.batteryLevels ?? UnifiedBattery.allLevels)
            case .legacy: state.battery = try await LegacyBattery.status(device)
            case .voltage: state.battery = try await BatteryVoltage.status(device)
            case nil: break
            }
        } catch {
            if !stops(error) { Log.debug("\(name): reading battery failed: \(error)") }
        }
    }

    /// The wheel's clutch: SmartShift 0x2110 whenever present (the tested path), else Enhanced 0x2111.
    enum Clutch { case smartShift, enhanced }

    /// Which clutch the mouse has, if any. Enhanced-only mice are untested: a malformed or
    /// feature-error reply to its lookup counts as none, but timeouts and transport failures throw.
    func clutch() async throws -> Clutch? {
        if try await device.hasFeature(SmartShift.id) { return .smartShift }
        do {
            return try await device.hasFeature(SmartShiftEnhanced.id) ? .enhanced : nil
        } catch where Self.isDeviceAnswer(error) {
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
            guard let clutch = try await clutch() else { return }
            enhanced = clutch == .enhanced
            let mode = state.scrollMode ?? config.scrollWheel?.mode?.smartShift
            let threshold = config.scrollWheel?.smartShiftThreshold
            let current = try await scrollMode(of: clutch)
            if mode != nil || threshold != nil {
                try await setScrollMode(clutch, mode ?? current, autoDisengage: threshold)
            }
            state.wheelMode = mode ?? current
        } catch where enhanced && Self.isDeviceAnswer(error) {
            Log.error("\(name): SmartShift Enhanced failed (untested mouse): \(error)")
        }
    }

    /// Each request `restore` makes waits this long at most, so one the mouse misses still leaves
    /// time for every other before the daemon's deadline (`Daemon.shutdownDeadline`).
    static let restoreTimeout: Duration = .milliseconds(400)

    /// The hand-backs `restore` makes, each one request when feature indices are cached.
    var restoreSteps: Int {
        wheelsToRestore.count + divertedControls.count + (state.preciseFrom != nil ? 1 : 0)
    }

    /// The wheels `restore` may have to hand back. One of unknown presence counts, since
    /// `restore` may still look it up and write it; the notched wheel is the main wheel only
    /// where there is no high-resolution one.
    private var wheelsToRestore: [Wheel] {
        guard wheelsMayBeDiverted else { return [] }
        return Wheel.allCases.filter {
            device.knownPresence(of: $0.feature) != false
                && !($0 == .notched && device.knownPresence(of: Wheel.main.feature) == true)
        }
    }

    /// Hands the mouse back in its native state: buttons undiverted and wheels reporting as
    /// ordinary HID scrolling, so it works without PureMouse. Used when PureMouse quits or pauses.
    func restore() async {
        finish()
        // Cancelled work stops at its next write, and its request in flight fails at once.
        await diversion.drain()
        await deviceActions.drain()
        let lease = device.lendTimeout(Self.restoreTimeout)
        defer { device.returnTimeout(lease) }
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
            await attempt("restore notched wheel") {
                if try await self.hasNotchedMainWheel() {
                    try await LowResWheel.setDiverted(self.device, false)
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
            await attempt("release \(ControlNames.describe(cid))") {
                try await ReprogControls.setDiverted(self.device, cid: cid, divert: false, rawXY: false)
            }
        }
        // Precise Pointer let go by the finish above: its slower speed is not left on the mouse.
        if state.preciseFrom != nil, let feature = state.dpiFeature {
            await attempt("restore pointer speed") { try await self.restorePointerSpeed(feature) }
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
