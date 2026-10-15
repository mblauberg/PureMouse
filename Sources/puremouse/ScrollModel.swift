import Foundation

/// Scroll maths: acceleration and smoothing. Pure logic, no I/O.

/// Turns wheel speed into a distance multiplier, so slow, deliberate notches move a fixed small
/// distance while a fast spin covers a long document. The curve rises early and flattens out,
/// so ordinary reading speeds feel brisk without fast spins flinging the page.
struct ScrollAcceleration {
    /// 0 is linear; 1 gives 1.5× at 5 notches per second, 2× at 9, 3× at 17 and 5× at 35.
    var strength: Double
    /// Speeds up to this many notches per second stay linear.
    var linearBelow = 2.0
    var maxGain = 8.0
    /// A pause this long starts a new burst with no speed history.
    var burstGap: Duration = .milliseconds(250)

    private var rate = 0.0  // smoothed notches per second
    private var last: ContinuousClock.Instant?
    private var lastSign = 0.0

    init(strength: Double) {
        self.strength = strength
    }

    /// The multiplier for `notches` of movement arriving at `now`.
    mutating func gain(notches: Double, at now: ContinuousClock.Instant) -> Double {
        let sign: Double = notches < 0 ? -1 : 1
        if let last, now - last < burstGap, sign == lastSign {
            // Event timing is quantised by the radio link, so floor the interval and smooth.
            let seconds = max((now - last).seconds, 0.004)
            rate = 0.6 * rate + 0.4 * abs(notches) / seconds
        } else {
            rate = 0
        }
        last = now
        lastSign = sign
        return min(maxGain, 1 + strength * 0.2 * pow(max(0, rate - linearBelow), 0.85))
    }
}

/// Spreads a scroll distance over several frames with exponential easing in two parts: most of
/// it lands within a few frames, so the page answers the wheel at once, and the rest glides to
/// rest more slowly, like momentum.
struct ScrollAnimator {
    /// Seconds for the glide to fall to 1/e; 0 moves everything in one frame.
    var timeConstant: Double
    /// Time constant of the immediate part, never slower than the glide.
    var responseTime: Double { min(timeConstant, 0.035) }
    /// Share of each movement left to the glide.
    var glideShare = 0.4

    private var quick = 0.0
    private var glide = 0.0
    private var carry = 0.0  // sub-pixel movement owed from earlier frames

    var remaining: Double { quick + glide }
    var isIdle: Bool { quick == 0 && glide == 0 && carry == 0 }

    init(timeConstant: Double) {
        self.timeConstant = timeConstant
    }

    mutating func add(_ pixels: Double) {
        // Reversing direction cancels the glide instead of first finishing it.
        if pixels * remaining < 0 { stop() }
        quick += pixels * (1 - glideShare)
        glide += pixels * glideShare
    }

    mutating func stop() {
        quick = 0
        glide = 0
        carry = 0
    }

    /// Movement for a frame lasting `dt` seconds: the exact distance, and whole pixels whose
    /// running total never drifts from it (for apps that read only integer deltas).
    mutating func step(_ dt: Double) -> (exact: Double, whole: Int) {
        guard !isIdle else { return (0, 0) }
        func decay(_ tau: Double) -> Double { tau > 0 ? 1 - exp(-dt / tau) : 1 }
        let quickMove = quick * decay(responseTime), glideMove = glide * decay(timeConstant)
        var move = quickMove + glideMove
        quick -= quickMove
        glide -= glideMove
        // Finish rather than crawl through a long tail of sub-pixel frames.
        if abs(remaining) < 1 {
            move += remaining
            quick = 0
            glide = 0
        }
        carry += move
        let done = remaining == 0
        let whole = done ? carry.rounded() : carry.rounded(.towardZero)
        carry = done ? 0 : carry - whole
        return (move, Int(whole))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
