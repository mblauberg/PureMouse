import PureMouseKit

/// Turns continuous thumb-wheel rotation into discrete steps, one per `threshold` units. Pure
/// logic, no I/O.
///
/// - The remainder carries over, so a fast spin gives several steps and a slow one still adds up
///   (Solaar's thumb-wheel rules work the same way); at most `maxPerEvent` fire for one report.
/// - Reversing direction, and the start of a new movement (`reset`), drop the remainder.
/// - `pacing` spaces steps out: at most one per `interval`. Tab and zoom shortcuts keep what
///   turned meanwhile for the next step (Logi Options+ repeats them every 40–50 ms); animated
///   actions such as switching Spaces `discard` it, so each step stands alone.
struct ThumbStepper {
    struct Pacing: Equatable {
        var interval: Duration = .zero
        var discards = false
    }

    var threshold: Int
    var pacing: Pacing
    var maxPerEvent = 4

    private var total = 0
    private var lastFired: ContinuousClock.Instant?

    init(threshold: Int, pacing: Pacing = Pacing()) {
        self.threshold = max(1, threshold)
        self.pacing = pacing
    }

    /// Diverted units per step: `step` of the wheel's native steps (18 per turn on the MX Master
    /// 3S, which reports 120 units per turn when diverted).
    static func threshold(step: Int, native: Int, diverted: Int) -> Int {
        max(1, Int((Double(step) * Double(diverted) / Double(max(1, native))).rounded()))
    }

    /// Media keys repeat freely; shortcuts at most one per 50 ms (zoom 40 ms), as Logi Options+
    /// paces tab and zoom repeats; Spaces, Mission Control and the other animated actions one
    /// per 300 ms (Logi's rotary desktop switching waits 200–600 ms), discarding turns between.
    static func pacing(left: Action, right: Action) -> Pacing {
        func pacing(_ action: Action) -> Pacing {
            switch action {
            case .none, .volumeUp, .volumeDown, .mute, .brightnessUp, .brightnessDown: Pacing()
            case .zoomIn, .zoomOut: Pacing(interval: .milliseconds(40))
            case .keys, .nextTab, .previousTab: Pacing(interval: .milliseconds(50))
            default: Pacing(interval: .milliseconds(300), discards: true)
            }
        }
        let l = pacing(left), r = pacing(right)
        return Pacing(interval: max(l.interval, r.interval), discards: l.discards || r.discards)
    }

    mutating func reset() {
        total = 0
    }

    /// Feeds signed units. Returns the steps to take: positive one way, negative the other.
    mutating func add(_ units: Int, at now: ContinuousClock.Instant = .now) -> Int {
        if units * total < 0 { total = 0 }
        let paced = pacing.interval > .zero
        if paced, let lastFired, now - lastFired < pacing.interval {
            guard !pacing.discards else { return 0 }
            // Held for the next step, but never more than one step's worth.
            total = max(-threshold, min(threshold, total + units))
            return 0
        }
        total += units
        let limit = paced ? 1 : maxPerEvent
        let steps = max(-limit, min(limit, total / threshold))
        guard steps != 0 else { return 0 }
        lastFired = now
        // A capped burst drops what it could not take rather than replaying it later.
        total = pacing.discards ? 0 : (total - steps * threshold) % threshold
        return steps
    }
}
