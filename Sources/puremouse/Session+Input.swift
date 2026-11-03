import Foundation
import PureMouseKit
import HIDPP

/// Turning the mouse's events into actions, scrolling and device actions.
extension Session {
    // MARK: Scrolling

    func profileUnderPointer() -> ScrollEngine.Profile {
        guard let app = ForegroundApp.shared.underPointer(), let profile = appProfiles[app.lowercased()] else {
            return globalProfile
        }
        Log.debug("\(name): scrolling with \(app)'s settings")
        return profile
    }

    // MARK: Events

    /// Records a battery broadcast from the selected source when it differs from what is known.
    private func batteryChanged(_ battery: UnifiedBattery.State?) {
        guard let battery, battery != state.battery else { return }
        state.battery = battery
        changed()
    }

    func handle(_ report: Report) {
        guard !finished else { return }
        if Receiver.isConnectionNotification(report, onReceiver: device.interface.isReceiver) {
            if onConnection?(report) == true { return }
            if Receiver.isLinkEstablished(report) {
                Log.info("\(name): link up")
                linkDown = false
                configure()
            } else {
                // The mouse is off or out of range: its releases will not arrive.
                scroll?.stop()
                dropHeld()
                linkWentDown()
                if state.online {
                    state.online = false
                    changed()
                }
            }
            return
        }
        linkDown = false  // it is talking
        reconfigureIfOffline()
        let feature = device.feature(at: report.featureIndex)
        // Late wheel and button reports from before a handoff: the pointer is on another Mac.
        if away, let feature, Wheel.allCases.map(\.feature).contains(feature) || feature == ReprogControls.id { return }
        switch feature {
        case HiResWheel.id:
            switch HiResWheel.parse(function: report.function, params: report.params) {
            case .scroll(let delta, _): scroll?.wheel(delta, perNotch: wheelMultiplier)
            case .ratchet(let engaged): Log.debug("\(name): ratchet \(engaged ? "engaged" : "released")")
            case nil: break
            }
        case LowResWheel.id:
            if case .scroll(let notches) = LowResWheel.parse(function: report.function, params: report.params) {
                scroll?.wheel(notches, perNotch: 1)
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
            if let battery = UnifiedBattery.parse(function: report.function, params: report.params,
                                                   levels: state.batteryLevels ?? UnifiedBattery.allLevels),
               battery != state.battery {
                Log.debug("\(name): battery \(battery.percent.map { "\($0)%" } ?? "?") \(battery.isCharging ? "charging" : "")")
                state.battery = battery
                changed()
            }
        case LegacyBattery.id:
            // Only the selected source is authoritative (0x1004, else 0x1000, else 0x1001).
            if state.batterySource == .legacy { batteryChanged(LegacyBattery.parse(function: report.function, params: report.params)) }
        case BatteryVoltage.id:
            if state.batterySource == .voltage { batteryChanged(BatteryVoltage.parse(function: report.function, params: report.params)) }
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
            if let first = pressed.first {
                Log.info("\(name): pressed \(ControlNames.describe(first)) for selection")
                onCapture?(first)
            }
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
            // setting and `inverted` (scrolling only), and follow the scope's `reversed`.
            let units = thumbSettings.reversed ? -event.rotation : event.rotation
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

    /// The plan for a press: the frontmost app's when an app entry names the control, else the
    /// global one. Only a control some app names needs the lookup. An app that sets the control to
    /// `"default"` names it (`AppSettings.buttons`) but has no binding for it: the mouse's own.
    private func plan(for cid: UInt16) -> PressPlan {
        if appButtons.contains(cid), let app = ForegroundApp.shared.frontmost(),
           let plans = appPlans[app.lowercased()] {
            Log.debug("\(name): buttons with \(app)'s settings")
            return plans[cid] ?? PressPlan(nil)
        }
        return globalPlans[cid] ?? PressPlan(nil)
    }

    /// A press: the click at once when it is the only trigger (`PressPlan.immediate`); otherwise
    /// the press is followed until its release, with the hold's deadline armed for it, or it is
    /// the second press of a double-click.
    private func press(_ cid: UInt16) {
        Log.debug("\(name): press \(ControlNames.describe(cid))")
        // A control that is Hold and Move in some scope is diverted with raw pointer motion, which
        // holds the pointer still. Where this press is not moving, the pointer must move.
        if let waiting = presses[cid], waiting.stage == .waiting {
            if bound[cid] == true { setPointerFree(cid, true) }
            waiting.deadline?.cancel()
            presses[cid] = Press(plan: waiting.plan, stage: .done)
            Log.debug("\(name): double-click")
            if let action = waiting.plan.doubleClick { perform(action) }
            return
        }
        // Another control's lone click is not kept waiting behind this press.
        for (other, press) in presses where press.stage == .waiting { clickAfterWaiting(other, press) }
        let plan = plan(for: cid)
        if !plan.moves, bound[cid] == true { setPointerFree(cid, true) }
        guard !plan.immediate else {
            pressed(plan.click, cid)
            return
        }
        var press = Press(plan: plan, stage: .down)
        switch plan.hold {
        case .move(let table):
            guard held.holdGesture(cid, table) else { return }
            recognizer.begin()
        case .action:
            press.deadline = environment.deadline(.milliseconds(config.holdMs)) { [weak self] in self?.holdReached(cid) }
        case .none:
            break
        }
        presses[cid] = press
    }

    /// An action fired while its control is down: Middle Click and Precise Pointer last until the
    /// control is let go; nil is the mouse's own behaviour.
    private func pressed(_ action: Action?, _ cid: UInt16) {
        switch action {
        case nil: performNative(cid)
        case .middleClick?: held.pressMiddle(cid)  // held until release, so it can drag
        case .precisePointer(let dpi)?: startPrecise(cid, dpi: dpi)
        case let action?: perform(action)
        }
    }

    /// The hold's deadline: the button is still down and nothing else has fired, so the hold
    /// fires, and its release will not click.
    private func holdReached(_ cid: UInt16) {
        guard var press = presses[cid], press.stage == .down, case .action(let action) = press.plan.hold else { return }
        press.stage = .done
        press.deadline = nil
        presses[cid] = press
        Log.debug("\(name): hold \(ControlNames.describe(cid))")
        pressed(action, cid)
    }

    /// Mouse Default: what the control does without PureMouse (`Config.nativeBehaviour`). A press
    /// bound only in other apps, or set to "default" here, comes to this; a control with no
    /// behaviour of its own does nothing.
    private func performNative(_ cid: UInt16) {
        switch Config.nativeBehaviour(of: cid) {
        case .click: held.clickNatively(cid)
        case .action(let action): perform(action)
        case nil: break
        }
    }

    /// A release: ends what the press holds; a press that fired nothing is a click, now or, when a
    /// double-click is watched for, once the wait for a second press runs out.
    private func release(_ cid: UInt16) {
        if pointerFree.contains(cid) { setPointerFree(cid, false) }
        if held.release(cid) != nil { _ = recognizer.end() }
        if precise == cid { endPrecise() }
        guard var press = presses.removeValue(forKey: cid) else { return }
        press.deadline?.cancel()
        press.deadline = nil
        guard press.stage == .down else { return }
        guard press.plan.doubleClick != nil else {
            perform(press.plan.click ?? .none)
            return
        }
        press.stage = .waiting
        let interval = config.doubleClickInterval(systemSeconds: environment.doubleClickSeconds())
        press.deadline = environment.deadline(.milliseconds(interval)) { [weak self] in self?.doubleClickMissed(cid) }
        presses[cid] = press
    }

    /// No second press came in time: the lone click fires.
    private func doubleClickMissed(_ cid: UInt16) {
        guard let press = presses[cid], press.stage == .waiting else { return }
        clickAfterWaiting(cid, press)
    }

    private func clickAfterWaiting(_ cid: UInt16, _ press: Press) {
        press.deadline?.cancel()
        presses[cid] = nil
        perform(press.plan.click ?? .none)
    }

    /// Lets go of every held button without acting on it, posting the releases of native clicks,
    /// Middle Click and Drag Lock, ends Precise Pointer, cancels every press's deadline, and ends
    /// any thumb-wheel movement: for when the mouse's own releases may never come.
    func dropHeld() {
        for press in presses.values { press.deadline?.cancel() }
        presses = [:]
        held.drop()
        endPrecise()
        // The mouse's own reporting flags are set again by the apply that follows.
        pointerFree = []
        thumbLast = nil
    }

    private func moved(dx: Int, dy: Int) {
        guard let gesture = held.gesture,
              let direction = recognizer.move(dx: dx, dy: dy) else { return }
        Log.debug("\(name): gesture \(direction)")
        presses[gesture.cid]?.stage = .done
        perform(gesture.gesture.action(for: direction))
    }

    /// Performs a one-shot action. Precise Pointer is not one: it is started by its press
    /// (`pressed`), and Kit accepts it only where that happens.
    private func perform(_ action: Action) {
        if case .dragLock = action {
            held.toggleDragLock()
            return
        }
        guard action.actsOnDevice else {
            environment.performSystem(action)
            return
        }
        // Queued so quick presses each take effect once, in order, and none lands mid-apply.
        deviceActions.enqueue { [self] in
            guard !finished else { return }
            switch action {
            case .cycleDPI: await cycleDPI()
            case .toggleScrollMode: await toggleScrollMode()
            case .haptic(let waveform): await playHaptic(waveform)
            default: break
            }
            // An action's lookup may be the first answer about a feature apply never needed.
            capabilitiesMayHaveChanged()
        }
    }

    private func playHaptic(_ waveform: HapticWaveform) async {
        guard !noticed.contains(.hapticMissing) else { return }
        do {
            guard try await device.hasFeature(Haptic.id) else {
                notice(.hapticMissing, "haptic action ignored; no 0x19B0 feature")
                return
            }
            try ensureOpen()
            if hapticCapabilities == nil { hapticCapabilities = try await Haptic.getCapabilities(device) }
            guard hapticCapabilities?.supports(waveform.id) == true else {
                if unsupportedHaptics.insert(waveform).inserted {
                    Log.info("\(name): haptic \(waveform.rawValue) ignored; waveform not supported")
                }
                return
            }
            try ensureOpen()
            try await Haptic.playWaveform(device, waveform: waveform.id)
        } catch {
            if !stops(error) { Log.error("\(name): haptic \(waveform.rawValue) failed: \(error)") }
        }
    }

    /// Drops the DPI chosen by `cycleDPI` and sets the config's, after any pending device action.
    /// The override goes at once, so a session replacing this one before the write runs inherits
    /// none and applies the config's itself; a `cycleDPI` queued earlier cannot bring it back.
    func useConfiguredDPI() {
        guard !finished else { return }
        state.liveDPI = nil
        deviceActions.enqueue { [self] in
            state.liveDPI = nil
            do {
                try await applyDPI()
                changed()
            } catch {
                if !stops(error) { Log.error("\(name): setting DPI failed: \(error)") }
            }
        }
    }

    private func cycleDPI() async {
        guard !config.dpiPresets.isEmpty else {
            Log.error("\(name): cycleDPI needs dpiPresets in the config")
            return
        }
        do {
            guard let feature = try await dpiFeature(), !state.dpiRefused else { return }
            let current = if let dpi = state.dpi { dpi } else { try await readDPI(feature).x }
            guard let next = Config.nextPreset(config.dpiPresets.map(supportedDPI(near:)), after: current) else { return }
            try await writeDPI(next, feature)
            state.liveDPI = next
            try await confirmDPI(next, feature)
            Log.debug("\(name): dpi \(next)")
            changed()
        } catch {
            if !stops(error) { Log.error("\(name): cycle DPI failed: \(error)") }
        }
    }

    private func toggleScrollMode() async {
        do {
            guard let clutch = try await clutch() else {
                notice(.toggleUnsupported, "toggleScrollMode needs SmartShift, which this mouse lacks")
                return
            }
            let next: SmartShift.Mode = try await scrollMode(of: clutch) == .ratchet ? .freespin : .ratchet
            try await setScrollMode(clutch, next)
            state.scrollMode = next
            state.wheelMode = next
            changed()
            Log.debug("\(name): scroll mode \(next)")
        } catch {
            if !stops(error) { Log.error("\(name): toggle scroll mode failed: \(error)") }
        }
    }
}
