import Foundation

/// Live defaults preserve the daemon's permission checks and set the reapply schedule. Tests can
/// exercise device behaviour without event-posting permission or the live waits: a test that sets
/// neither gets one slow retry and the device's own timeout.
struct SessionEnvironment {
    var canPostEvents: Bool
    /// The wait between the three attempts of one `Session.configure`.
    var configureRetryDelay: Duration = .seconds(5)
    var now: () -> ContinuousClock.Instant = { .now }
    /// How the daemon waits between attempts to adopt an endpoint that did not answer (`Backoff`).
    var adoptionSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The scroll engine's frame clock and where it posts: a test supplies its own of each.
    var frameClock: @MainActor () -> FrameClock = { FrameClock() }
    var postScroll: (Int, Int) -> Void = { ScrollEvent.post(dx: $0, dy: $1) }
    /// The system's natural-scrolling setting, which the engine re-reads at each burst.
    var naturalScrolling: () -> Bool = { SystemScrollSettings.naturalScrolling }
    /// How long each request of a configure attempt waits for its reply; nil leaves the device's
    /// own timeout. Short, so a request lost while the mouse was still waking fails in time for the
    /// next attempt.
    var attemptTimeout: Duration?
    /// The wall clock, for the time settings were applied.
    var date: () -> Date = { Date() }

    /// Three attempts, `retryDelay` apart, each request of which waits at most `attemptTimeout`
    /// (per request, not per attempt). A mouse answering from any moment in the window has its
    /// settings back within about a second of that moment: the request in flight, then the rest of
    /// the apply or one delay and another attempt. A mouse that answers nothing is given up on only
    /// after its attempts have waited on every request they make, about 10 to 15 s (several
    /// lookups an attempt can do without each wait out their timeout), and is then offline, not
    /// failed. A mouse that returns later announces itself and starts a new configure.
    static let reapplyAttemptTimeout: Duration = .milliseconds(600)
    static let reapplyRetryDelay: Duration = .milliseconds(200)

    static var live: Self {
        Self(canPostEvents: Permissions.current.contains(.accessibility),
             configureRetryDelay: reapplyRetryDelay, attemptTimeout: reapplyAttemptTimeout)
    }
}
