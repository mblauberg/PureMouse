import PureMouseKit

/// Turns continuous thumb-wheel rotation into discrete steps, one per `threshold` units. Pure
/// logic, no I/O.
///
/// - The remainder carries over, so a fast spin gives several steps and a slow one still adds up
///   (Solaar's thumb-wheel rules work the same way); at most `maxPerEvent` fire for one report.
/// - Reversing direction, and the start of a new movement (`reset`), drop the remainder.
/// - With a `cooldown` (for actions that animate, such as switching Spaces) each step stands
///   alone: one fires, and movement until the cooldown ends is discarded.
struct ThumbStepper {
    var threshold: Int
    var cooldown: Duration
    var maxPerEvent = 4

    private var total = 0
    private var lastFired: ContinuousClock.Instant?

    init(threshold: Int, cooldown: Duration = .zero) {
        self.threshold = max(1, threshold)
        self.cooldown = cooldown
    }

    /// Diverted units per step: `step` of the wheel's native steps (18 per turn on the MX Master
    /// 3S, which reports 120 units per turn when diverted).
    static func threshold(step: Int, native: Int, diverted: Int) -> Int {
        max(1, Int((Double(step) * Double(diverted) / Double(max(1, native))).rounded()))
    }

    /// Animated actions get a pause between steps; shortcuts and media keys repeat freely.
    static func cooldown(left: Action, right: Action) -> Duration {
        func repeats(_ action: Action) -> Bool {
            switch action {
            case .none, .keys, .volumeUp, .volumeDown, .brightnessUp, .brightnessDown,
                 .nextTab, .previousTab, .zoomIn, .zoomOut: true
            default: false
            }
        }
        return repeats(left) && repeats(right) ? .zero : .milliseconds(400)
    }

    mutating func reset() {
        total = 0
    }

    /// Feeds signed units. Returns the steps to take: positive one way, negative the other.
    mutating func add(_ units: Int, at now: ContinuousClock.Instant = .now) -> Int {
        if units * total < 0 { total = 0 }
        if cooldown > .zero, let lastFired, now - lastFired < cooldown { return 0 }
        total += units
        let limit = cooldown > .zero ? 1 : maxPerEvent
        let steps = max(-limit, min(limit, total / threshold))
        guard steps != 0 else { return 0 }
        lastFired = now
        // A capped burst drops what it could not take rather than replaying it later.
        total = cooldown > .zero ? 0 : (total - steps * threshold) % threshold
        return steps
    }
}
