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

    func handle(_ report: Report) {
        guard !finished else { return }
        if report.featureIndex == Receiver.connectionNotification {
            if onConnection?(report) == true { return }
            if Receiver.isLinkEstablished(report) {
                Log.info("\(name): link up")
                configure()
            } else {
                // The mouse is off or out of range: its releases will not arrive.
                scroll?.stop()
                dropHeld()
                if state.online {
                    state.online = false
                    changed()
                }
            }
            return
        }
        let feature = device.feature(at: report.featureIndex)
        // Late wheel and button reports from before a handoff: the pointer is on another Mac.
        if away, let feature, [HiResWheel.id, ThumbWheel.id, ReprogControls.id].contains(feature) { return }
        switch feature {
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
            if let battery = UnifiedBattery.parse(function: report.function, params: report.params,
                                                   levels: state.batteryLevels ?? UnifiedBattery.allLevels),
               battery != state.battery {
                Log.debug("\(name): battery \(battery.percent.map { "\($0)%" } ?? "?") \(battery.isCharging ? "charging" : "")")
                state.battery = battery
                changed()
            }
        case LegacyBattery.id:
            // If both features exist, only 0x1004 is authoritative.
            if state.legacyBatterySelected,
               let battery = LegacyBattery.parse(function: report.function, params: report.params),
               battery != state.battery {
                state.battery = battery
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
    /// Only a control some app names needs the lookup.
    private func binding(for cid: UInt16) -> Config.Binding? {
        if appButtons.contains(cid), let app = ForegroundApp.shared.frontmost(), let scoped = config.settings(forApp: app) {
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
    func dropHeld() {
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
        // Queued so quick presses each take effect once, in order, and none lands mid-apply.
        deviceActions.enqueue { [self] in
            guard !finished else { return }
            switch action {
            case .cycleDPI: await cycleDPI()
            case .toggleScrollMode: await toggleScrollMode()
            case .haptic(let waveform): await playHaptic(waveform)
            default: break
            }
        }
    }

    private func playHaptic(_ waveform: HapticWaveform) async {
        guard !hapticMissingLogged else { return }
        do {
            guard try await device.hasFeature(Haptic.id) else {
                Log.info("\(name): haptic action ignored; no 0x19B0 feature")
                hapticMissingLogged = true
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
                guard try await device.hasFeature(AdjustableDPI.id) else { return }
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
            guard try await device.hasFeature(AdjustableDPI.id) else { return }
            let current = if let dpi = state.dpi { dpi } else { try await AdjustableDPI.get(device) }
            guard let next = Config.nextPreset(config.dpiPresets.map(supportedDPI(near:)), after: current) else { return }
            try ensureOpen()
            try await AdjustableDPI.set(device, dpi: next)
            state.liveDPI = next
            try await readDPI()
            Log.debug("\(name): dpi \(next)")
            changed()
        } catch {
            if !stops(error) { Log.error("\(name): cycle DPI failed: \(error)") }
        }
    }

    private func toggleScrollMode() async {
        do {
            guard let clutch = try await clutch() else {
                Log.error("\(name): toggleScrollMode needs SmartShift")
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
