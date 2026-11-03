import Foundation
import Testing
@testable import PureMouseAppSupport

@MainActor
@Suite struct BackgroundActivityTests {
    @Test func theToleranceIsAlwaysShorterThanTheInterval() {
        // NSBackgroundActivityScheduler raises an exception otherwise (found on the footprint rig:
        // a check already due asked for a 60 s interval and a one-hour tolerance).
        for delay in [-5, 0, 1, 59, 60, 61, 119, 120, 3_600, 7_199, 7_200, 86_400].map(TimeInterval.init) {
            let timing = BackgroundActivity.timing(after: delay)
            #expect(timing.tolerance < timing.interval, "delay \(delay)")
            #expect(timing.interval >= BackgroundActivity.minimumDelay)
            #expect(timing.tolerance <= BackgroundActivity.maximumTolerance)
        }
    }

    @Test func theEarliestRunIsTheWantedDelayNotBefore() {
        // The system may run the activity up to the tolerance before the interval is up.
        for delay in [0, 30, 60, 600, 3_600, 86_400].map(TimeInterval.init) {
            let timing = BackgroundActivity.timing(after: delay)
            #expect(timing.interval - timing.tolerance >= delay)
        }
        let day = BackgroundActivity.timing(after: 24 * 60 * 60)
        #expect(day.tolerance == 60 * 60 && day.interval == 25 * 60 * 60)
        #expect(BackgroundActivity.timing(after: 0) == (interval: 90, tolerance: 30))
    }

    /// The live scheduler accepts both a due check and one a day away, and cancels (a real
    /// `NSBackgroundActivityScheduler`, cancelled at once, so nothing runs).
    @Test func theLiveSchedulerAcceptsDueAndFarOffChecksAndCancels() {
        let activity = BackgroundActivity(identifier: "io.github.mblauberg.puremouse.tests.update-check.\(UUID().uuidString)")
        activity.schedule(after: 0) { done in done() }
        activity.schedule(after: 24 * 60 * 60) { done in done() }
        activity.cancel()
    }
}
