/// Turns pointer motion during a button hold into four-way directions. Pure logic, no I/O.
///
/// - Motion in the first `settle` after the press is ignored: pressing a thumb button jolts the
///   mouse, and that jolt must not pick the direction.
/// - A direction fires once travel reaches `threshold` along an axis that clearly dominates
///   (by `dominance`×). Ambiguous diagonals keep accumulating until they resolve.
/// - Continuing to move fires again, at most once per `repeatInterval`; motion during that
///   interval is discarded so each repeat needs fresh travel.
/// - A hold that fires nothing counts as a click.
struct GestureRecognizer {
    enum Direction: Equatable { case up, down, left, right }

    var threshold: Int
    var repeatInterval: Duration
    var settle: Duration = .milliseconds(40)
    var dominance = 1.5

    private var x = 0
    private var y = 0
    private var pressed: ContinuousClock.Instant?
    private var lastFired: ContinuousClock.Instant?

    init(threshold: Int, repeatInterval: Duration) {
        self.threshold = max(1, threshold)
        self.repeatInterval = repeatInterval
    }

    /// Sensor counts for a physical distance at the given resolution.
    static func counts(millimetres: Double, dpi: Int) -> Int {
        Int((millimetres / 25.4 * Double(dpi)).rounded())
    }

    mutating func begin(at now: ContinuousClock.Instant = .now) {
        x = 0
        y = 0
        pressed = now
        lastFired = nil
    }

    /// Feeds raw motion (+x right, +y down). Returns a direction when one fires.
    mutating func move(dx: Int, dy: Int, at now: ContinuousClock.Instant = .now) -> Direction? {
        if let pressed, now - pressed < settle { return nil }
        if let lastFired, now - lastFired < repeatInterval { return nil }
        x += dx
        y += dy
        let (major, minor) = abs(x) >= abs(y) ? (abs(x), abs(y)) : (abs(y), abs(x))
        guard major >= threshold else { return nil }
        // Fire on a clear axis, or anyway once a diagonal has gone well past the threshold.
        guard Double(major) >= dominance * Double(minor) || major >= 3 * threshold else { return nil }
        let direction: Direction = abs(x) >= abs(y) ? (x < 0 ? .left : .right) : (y < 0 ? .up : .down)
        x = 0
        y = 0
        lastFired = now
        return direction
    }

    /// Ends the hold. Returns true when it should count as a click.
    mutating func end() -> Bool {
        let click = pressed != nil && lastFired == nil
        x = 0
        y = 0
        pressed = nil
        lastFired = nil
        return click
    }
}
