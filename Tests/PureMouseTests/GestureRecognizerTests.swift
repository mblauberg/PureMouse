import Testing
@testable import puremouse

@Suite struct GestureRecognizerTests {
    let t0 = ContinuousClock.now
    var later: ContinuousClock.Instant { t0 + .milliseconds(100) }

    func recognizer() -> GestureRecognizer {
        var g = GestureRecognizer(threshold: 50, repeatInterval: .milliseconds(400))
        g.begin(at: t0)
        return g
    }

    @Test func clickWhenNoDirectionFires() {
        var g = recognizer()
        let d = g.move(dx: 10, dy: -20, at: later)
        #expect(d == nil)
        let click = g.end()
        #expect(click)
    }

    @Test func pressJoltIsIgnored() {
        var g = recognizer()
        let jolt = g.move(dx: 0, dy: 400, at: t0 + .milliseconds(10))
        #expect(jolt == nil)
        let d = g.move(dx: -60, dy: 0, at: later)
        #expect(d == .left)
    }

    @Test func dominantAxisWins() {
        var g = recognizer()
        let a = g.move(dx: -30, dy: 10, at: later)
        let b = g.move(dx: -25, dy: 5, at: later)
        #expect(a == nil && b == .left)
        let click = g.end()
        #expect(!click)
    }

    @Test func diagonalWaitsUntilItResolves() {
        var g = recognizer()
        let a = g.move(dx: 55, dy: -50, at: later)
        #expect(a == nil)
        let b = g.move(dx: 0, dy: -40, at: later)  // now clearly up: |y| 90 vs |x| 55
        #expect(b == .up)
    }

    @Test func repeatsOnlyAfterIntervalWithFreshTravel() {
        var g = recognizer()
        let first = g.move(dx: 60, dy: 0, at: later)
        let discarded = g.move(dx: 200, dy: 0, at: later + .milliseconds(100))
        let short = g.move(dx: 30, dy: 0, at: later + .milliseconds(450))
        let second = g.move(dx: 30, dy: 0, at: later + .milliseconds(460))
        #expect(first == .right && discarded == nil && short == nil && second == .right)
    }

    @Test func endResetsState() {
        var g = recognizer()
        _ = g.move(dx: 0, dy: 80, at: later)
        _ = g.end()
        g.begin(at: t0)
        let d = g.move(dx: 0, dy: 10, at: later)
        let click = g.end()
        #expect(d == nil && click)
    }

    @Test func millimetresToCounts() {
        #expect(GestureRecognizer.counts(millimetres: 25.4, dpi: 1650) == 1650)
        #expect(GestureRecognizer.counts(millimetres: 4, dpi: 1650) == 260)
    }
}
