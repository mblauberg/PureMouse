import Foundation
import PureMouseKit
import HIDPP

/// Which controls and wheels report to PureMouse: capture, diversion, Universal Control hand-off.
extension Session {
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
            for cid in extras where session.capturing != nil && !session.away {
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
        try await Independently.each(releasing.sorted(), stopsOn: { self.stops($0) }) { cid in
            do {
                try await setDiverted(cid, false)
                releasing.remove(cid)
            } catch {
                Log.debug("\(name): releasing 0x\(String(cid, radix: 16)) failed: \(error)")
                throw error
            }
        }
    }

    // MARK: Diversion

    /// A diversion write on this session's behalf; refused once the session is finished.
    private func setDiverted(_ cid: UInt16, _ divert: Bool, rawXY: Bool = false) async throws {
        try ensureOpen()
        try await ReprogControls.setDiverted(device, cid: cid, divert: divert, rawXY: rawXY)
    }

    /// Queues `body` to run after every diversion change asked for before it and before any
    /// asked for after. Diversion state is read when the body runs, so a later change (say
    /// capture ending mid-apply) is made by its own body afterwards rather than raced.
    @discardableResult
    private func enqueueDiversion(_ body: @escaping (Session) async throws -> Void) -> Task<Void, Error> {
        diversion.enqueue {
            try await body(self)
        } onFailure: { [weak self] error in
            guard let self, !self.finished else { return }
            // Usually asleep: the next apply diverts or releases them.
            Log.debug("\(self.name): diversion change failed: \(error)")
        }
    }

    /// Diverts the controls the session wants (`Handoff.wantedControls`) and releases the rest:
    /// those owed a release, and while away the bound and capturing ones too, each independently.
    private func applyDiversion() async throws {
        let wanted = Handoff.wantedControls(bound: Set(bound.keys), capturing: capturing, away: away)
        let unwanted = Set(bound.keys).union(capturing ?? []).subtracting(wanted)
        // Each control stands alone; a failed one keeps counting in `divertedControls` (it is
        // owed a release, bound or capturing), so the next apply and `restore` try it again.
        let changes = unwanted.sorted().map { ($0, false) } + wanted.sorted().map { ($0, true) }
        try await Independently.each([nil] + changes.map(Optional.some), stopsOn: { self.stops($0) }) { change in
            guard let (cid, divert) = change else { return try await releaseAll() }
            try await setDiverted(cid, divert, rawXY: divert && bound[cid] == true)
        }
    }

    // MARK: Universal Control

    /// Hands the wheels and diverted controls back to macOS while the pointer is on another Mac
    /// (`away`), so Universal Control forwards them, and takes them again when it returns. DPI,
    /// SmartShift and the rest stay applied. A change that fails (say the mouse is asleep) is
    /// made by the next apply, which reads `away`.
    func setAway(_ away: Bool) {
        guard !finished, away != self.away else { return }
        self.away = away
        // Nothing half-done is left behind: no glide, no held gesture.
        scroll?.stop()
        dropHeld()
        enqueueDiversion { session in
            try await session.applyInputs(wheels: session.scroll != nil || session.wheelsMayBeDiverted)
        }
    }

    /// Sets the wheels (wheels first, as in `restore`) and then the controls, each step on its
    /// own: a control that fails to release must not keep the wheels from being handed back.
    func applyInputs(wheels: Bool) async throws {
        try await Independently.each(wheels ? [true, false] : [false], stopsOn: { self.stops($0) }) { isWheels in
            if isWheels { try await applyWheels() } else { try await applyDiversion() }
        }
    }

    // MARK: Wheels

    /// With smooth scrolling, both wheels report to PureMouse at full resolution and direction is
    /// handled in software; thumb-wheel actions take the thumb wheel alone. Otherwise they report
    /// as ordinary HID scrolling (Logi Options+ leaves them diverted, which would leave them dead
    /// without it), inverted in hardware.
    private func applyWheels() async throws {
        try ensureOpen()
        // Taking the wheels over without permission to post scroll events would silence them.
        let accessibility = Permissions.current.contains(.accessibility)
        let takeOver = Handoff.wheelsDiverted(scrolling: scroll != nil, accessibility: accessibility, away: away)
        if scroll != nil && !accessibility { Log.error("\(name): no Accessibility permission; leaving the wheels native") }
        let smooth = takeOver && smoothAnywhere
        // Set before diverting, so `restore` hands them back even if a write below fails.
        if takeOver { wheelsMayBeDiverted = true }
        // Each wheel stands alone: a main wheel that times out must not leave the thumb wheel diverted.
        try await Independently.each([Wheel.main, .thumb], stopsOn: { self.stops($0) }) {
            try await applyWheel($0, takeOver: takeOver, smooth: smooth)
        }
        // Reached only when both were set, so a wheel that failed still counts as maybe diverted.
        if !takeOver { wheelsMayBeDiverted = false }
    }

    private enum Wheel { case main, thumb }

    /// The main wheel reports to PureMouse only for smooth scrolling; the thumb wheel whenever
    /// the wheels are taken over (smooth scrolling or thumb-wheel actions).
    private func applyWheel(_ wheel: Wheel, takeOver: Bool, smooth: Bool) async throws {
        switch wheel {
        case .main:
            guard try await device.hasFeature(HiResWheel.id) else { return }
            var inverted = false
            if smooth {
                wheelMultiplier = try await HiResWheel.multiplier(device)
            } else if let configured = config.scrollWheel?.inverted {
                inverted = configured
            } else {
                inverted = try await HiResWheel.mode(device).inverted  // not configured: keep
            }
            try ensureOpen()
            try await HiResWheel.setMode(device, .init(diverted: smooth, highResolution: smooth, inverted: inverted))
        case .thumb:
            state.hasThumbWheel = try await device.hasFeature(ThumbWheel.id)
            guard state.hasThumbWheel else { return }
            var inverted = false
            if takeOver {
                thumbInfo = try await ThumbWheel.info(device)
            } else if let configured = config.thumbWheel?.inverted {
                inverted = configured
            } else {
                inverted = try await ThumbWheel.reporting(device).inverted
            }
            try ensureOpen()
            try await ThumbWheel.setReporting(device, .init(diverted: takeOver, inverted: inverted))
        }
    }
}
