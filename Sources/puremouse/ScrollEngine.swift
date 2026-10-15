import CoreGraphics
import CoreVideo
import Foundation

/// PureMouse's own smooth scrolling, replacing Mos: wheel movement arrives over HID++ (the wheels
/// are diverted, so macOS never sees them) and leaves as pixel scroll events, eased over a few
/// display frames. Idle costs nothing; the frame clock only runs while a scroll is gliding.
@MainActor
final class ScrollEngine {
    /// How scrolling feels. One profile applies everywhere; per-app profiles would only need
    /// to pick a different one when a burst starts (see `beginBurstIfIdle`).
    struct Profile {
        var speed = 1.0
        var horizontalSpeed = 1.0
        var acceleration = 1.0
        var smoothing: Duration = .milliseconds(125)
        var shiftScrollsHorizontally = true
        /// Directions relative to the system scroll direction, as with the hardware invert bits.
        var invertVertical = false
        var invertHorizontal = false
    }

    /// Distances at speed 1 and no acceleration.
    static let pixelsPerNotch = 40.0
    static let pixelsPerThumbRotation = 360.0
    /// A pause this long ends a burst; the next input re-reads system settings.
    private static let burstGap: Duration = .milliseconds(500)

    private(set) var profile: Profile
    private var vertical: ScrollAnimator
    private var horizontal: ScrollAnimator
    private var wheelAcceleration: ScrollAcceleration
    private var thumbAcceleration: ScrollAcceleration
    private var naturalScrolling = SystemScrollSettings.naturalScrolling
    private var lastInput: ContinuousClock.Instant?
    private let clock = FrameClock()

    init(profile: Profile) {
        self.profile = profile
        // Smoothing is the time the glide takes to come to rest, about three time constants.
        let tau = profile.smoothing.seconds / 3
        vertical = ScrollAnimator(timeConstant: tau)
        horizontal = ScrollAnimator(timeConstant: tau)
        wheelAcceleration = ScrollAcceleration(strength: profile.acceleration)
        thumbAcceleration = ScrollAcceleration(strength: profile.acceleration)
        clock.onFrame = { [weak self] dt in self?.frame(dt) }
    }

    /// Main-wheel movement in device units: `perNotch` per notch, positive away from the user.
    func wheel(_ units: Int, perNotch: Int) {
        let now = ContinuousClock.now
        beginBurstIfIdle(now)
        // Classic direction: positive scrolls content toward its top.
        let notches = Double(units) / Double(perNotch) * direction(inverted: profile.invertVertical)
        let pixels = notches * Self.pixelsPerNotch * profile.speed
            * wheelAcceleration.gain(notches: notches, at: now)
        if profile.shiftScrollsHorizontally, CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) {
            horizontal.add(pixels)  // shift + wheel up scrolls left, as on other platforms
        } else {
            vertical.add(pixels)
        }
        startGlide()
    }

    /// Thumb-wheel movement in device units, `perRotation` per full turn. The raw sign already
    /// matches the horizontal axis (positive scrolls content toward its left edge).
    func thumb(_ units: Int, perRotation: Int, nativeSteps: Int) {
        let now = ContinuousClock.now
        beginBurstIfIdle(now)
        let rotations = Double(units) / Double(perRotation) * direction(inverted: profile.invertHorizontal)
        // Accelerate on the wheel's native detents so both wheels share one speed scale.
        let gain = thumbAcceleration.gain(notches: rotations * Double(nativeSteps), at: now)
        horizontal.add(rotations * Self.pixelsPerThumbRotation * profile.horizontalSpeed * gain)
        startGlide()
    }

    /// Without a frame clock, scrolling still works, just unsmoothed.
    private func startGlide() {
        if !clock.start() { frame(.infinity) }
    }

    /// Drops any glide in progress, e.g. when the device goes away.
    func stop() {
        vertical.stop()
        horizontal.stop()
        clock.stop()
    }

    private func beginBurstIfIdle(_ now: ContinuousClock.Instant) {
        defer { lastInput = now }
        guard lastInput.map({ now - $0 >= Self.burstGap }) ?? true else { return }
        naturalScrolling = SystemScrollSettings.naturalScrolling
        Log.debug("scroll: new burst (natural scrolling \(naturalScrolling ? "on" : "off"))")
    }

    /// Synthetic events skip the system's natural-scrolling flip, so apply it here, the same
    /// way it applies to a real wheel.
    private func direction(inverted: Bool) -> Double {
        inverted != naturalScrolling ? -1 : 1
    }

    private func frame(_ dt: Double) {
        let dy = vertical.step(dt).whole
        let dx = horizontal.step(dt).whole
        if dx != 0 || dy != 0 { ScrollEvent.post(dx: dx, dy: dy) }
        if vertical.isIdle && horizontal.isIdle { clock.stop() }
    }
}

enum SystemScrollSettings {
    /// System Settings › Mouse/Trackpad › Natural scrolling. On unless turned off.
    static var naturalScrolling: Bool {
        let key = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool ?? true
    }
}

enum ScrollEvent {
    /// Posts a continuous (trackpad-style) pixel scroll at the HID level, as a real device
    /// would, carrying the current modifier keys so cmd-zoom and similar shortcuts work. No
    /// gesture phases, like Mos: phased horizontal scrolls trigger browser swipe navigation.
    static func post(dx: Int, dy: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx),
                                  wheel3: 0) else { return }
        // Whole pixels only: the point-delta fields are integers, and writing a fractional value
        // replaces the delta with its truncation, losing distance every frame.
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cghidEventTap)
    }
}

/// Calls `onFrame` with the frame duration once per refresh of the display under the pointer,
/// so each frame of a glide moves an even distance. Runs only between `start` and `stop`.
@MainActor
final class FrameClock {
    var onFrame: ((Double) -> Void)?

    private var link: CVDisplayLink?
    private var running = false
    private var lastHostTime: UInt64?
    /// Ticks queued by an earlier start/stop cycle are discarded.
    private var generation = 0
    private let secondsPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Returns false if the display link cannot run.
    @discardableResult
    func start() -> Bool {
        guard !running else { return true }
        if link == nil { link = makeLink() }
        guard let link else { return false }
        if let display = Self.displayUnderPointer() { CVDisplayLinkSetCurrentCGDisplay(link, display) }
        lastHostTime = nil
        generation &+= 1
        let generation = generation
        // The handler runs on CoreVideo's thread; hop to the main queue with the frame's time.
        CVDisplayLinkSetOutputHandler(link) { @Sendable [weak self] _, _, outputTime, _, _ in
            let hostTime = outputTime.pointee.hostTime
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tick(hostTime, generation) } }
            return kCVReturnSuccess
        }
        running = CVDisplayLinkStart(link) == kCVReturnSuccess
        return running
    }

    func stop() {
        guard running, let link else { return }
        running = false
        CVDisplayLinkStop(link)
    }

    private func makeLink() -> CVDisplayLink? {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess else { return nil }
        return link
    }

    private func tick(_ hostTime: UInt64, _ tickGeneration: Int) {
        guard running, tickGeneration == generation, let link else { return }
        let dt = lastHostTime.map { Double(hostTime &- $0) * secondsPerHostTick }
            ?? CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
        lastHostTime = hostTime
        // Guard against odd timestamps (display change, wake) producing a huge or zero step.
        onFrame?(min(max(dt, 0.002), 0.05))
    }

    private static func displayUnderPointer() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }
}
