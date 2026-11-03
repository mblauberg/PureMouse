import HIDPPTesting
import Testing

// `eventually` is the wait every main-actor test uses. All `@MainActor` tests of a run share one
// main actor, so a yield can queue behind seconds of other tests' work: that must not time out a
// condition that is only waiting its turn.
@MainActor
struct EventuallyTests {
    /// Holds the main actor for `milliseconds`, as a heavy test body does.
    private func hog(_ milliseconds: Int, then done: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let end = ContinuousClock.now + .milliseconds(milliseconds)
            while ContinuousClock.now < end {}
            done()
        }
    }

    @Test func aWaitQueuedBehindBusyMainActorWorkIsNotTimedOutByIt() async throws {
        var finished = 0
        for _ in 0..<3 { hog(250) { finished += 1 } }
        // The three bodies run before this wait is resumed: 750 ms against a 300 ms deadline.
        try await eventually(within: .milliseconds(300)) { finished == 3 }
    }

    @Test func aConditionThatNeverHoldsFails() async {
        await #expect(throws: EventuallyTimedOut.self) { try await eventually(within: .milliseconds(50)) { false } }
    }

    @Test func aConditionThatAlreadyHoldsReturnsAtOnce() async throws {
        try await eventually(within: .milliseconds(1)) { true }
    }
}
