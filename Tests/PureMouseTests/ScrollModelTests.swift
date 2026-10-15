import Testing
@testable import puremouse

struct ScrollModelTests {
    @Test func animatorDeliversExactDistance() {
        var animator = ScrollAnimator(timeConstant: 0.05)
        animator.add(40)
        var total = 0, frames = 0
        while !animator.isIdle {
            total += animator.step(0.02).whole
            frames += 1
        }
        #expect(total == 40)
        #expect(frames > 3 && frames < 20)
    }

    @Test func exactAndWholeAgree() {
        var animator = ScrollAnimator(timeConstant: 0.04)
        animator.add(7.5)
        var exact = 0.0, whole = 0
        while !animator.isIdle {
            let step = animator.step(0.008)
            exact += step.exact
            whole += step.whole
        }
        #expect(abs(exact - 7.5) < 1e-9)
        #expect(whole == 8)
    }

    @Test func animatorFrontLoadsMotion() {
        var animator = ScrollAnimator(timeConstant: 0.05)
        animator.add(100)
        let first = animator.step(0.02).exact, second = animator.step(0.02).exact
        #expect(first > second && second > 0)
    }

    @Test func longGlideStillRespondsQuickly() {
        var animator = ScrollAnimator(timeConstant: 0.1)
        animator.add(100)
        var moved = 0.0
        for _ in 0..<4 { moved += animator.step(0.02).exact }
        #expect(moved > 65)  // the page answers within a few frames
        #expect(!animator.isIdle)  // while the glide carries on
    }

    @Test func animatorWithoutSmoothingIsImmediate() {
        var animator = ScrollAnimator(timeConstant: 0)
        animator.add(-37)
        #expect(animator.step(0.02).whole == -37)
        #expect(animator.isIdle)
    }

    @Test func reversalCancelsGlide() {
        var animator = ScrollAnimator(timeConstant: 0.05)
        animator.add(200)
        _ = animator.step(0.02)
        animator.add(-40)
        var total = 0
        while !animator.isIdle { total += animator.step(0.02).whole }
        #expect(total == -40)
    }

    @Test func slowScrollingIsLinear() {
        var acceleration = ScrollAcceleration(strength: 1)
        let start = ContinuousClock.now
        // One notch every 400 ms is a new burst each time.
        for i in 0..<5 {
            #expect(acceleration.gain(notches: 1, at: start + .milliseconds(400 * i)) == 1)
        }
    }

    @Test func fastScrollingAccelerates() {
        var acceleration = ScrollAcceleration(strength: 1)
        let start = ContinuousClock.now
        var gain = 1.0
        // 40 notches per second: a quick free-spin.
        for i in 0..<20 { gain = acceleration.gain(notches: 1, at: start + .milliseconds(25 * i)) }
        #expect(gain > 3 && gain <= acceleration.maxGain)
    }

    @Test func zeroStrengthIsLinear() {
        var acceleration = ScrollAcceleration(strength: 0)
        let start = ContinuousClock.now
        var gain = 0.0
        for i in 0..<20 { gain = acceleration.gain(notches: 1, at: start + .milliseconds(10 * i)) }
        #expect(gain == 1)
    }

    @Test func directionChangeResetsSpeed() {
        var acceleration = ScrollAcceleration(strength: 1)
        let start = ContinuousClock.now
        for i in 0..<20 { _ = acceleration.gain(notches: 1, at: start + .milliseconds(25 * i)) }
        #expect(acceleration.gain(notches: -1, at: start + .milliseconds(510)) == 1)
    }

    @Test func unsmoothedScrollPostsWholePixelsWithoutLosingDistance() {
        var carry = PixelCarry()
        #expect(carry.take(40) == 40)
        // Fractional movements add up rather than truncating or rounding away.
        let moves = (0..<10).map { _ in carry.take(0.4) }
        #expect(moves.reduce(0, +) == 4)
        #expect(moves.allSatisfy { $0 == 0 || $0 == 1 })
        #expect(carry.take(-2.5) == -2)
        #expect(carry.take(-0.5) == -1)
    }

    @Test func unsmoothedReversalDropsTheFraction() {
        var carry = PixelCarry()
        #expect(carry.take(0.9) == 0)
        #expect(carry.take(-0.9) == 0)  // the 0.9 owed upward is not taken from the downward move
        #expect(carry.take(-0.2) == -1)
    }
}
