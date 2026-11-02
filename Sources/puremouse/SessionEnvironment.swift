/// Live defaults preserve the daemon's permission checks and retry cadence. Tests can exercise
/// device behaviour without event-posting permission or five-second retry sleeps.
struct SessionEnvironment {
    var canPostEvents: Bool
    var configureRetryDelay: Duration = .seconds(5)
    var now: () -> ContinuousClock.Instant = { .now }
    /// How the daemon waits between attempts to adopt an endpoint that did not answer (`Backoff`).
    var adoptionSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The scroll engine's frame clock and where it posts: a test supplies its own of each.
    var frameClock: @MainActor () -> FrameClock = { FrameClock() }
    var postScroll: (Int, Int) -> Void = { ScrollEvent.post(dx: $0, dy: $1) }
    /// The system's natural-scrolling setting, which the engine re-reads at each burst.
    var naturalScrolling: () -> Bool = { SystemScrollSettings.naturalScrolling }

    static var live: Self { Self(canPostEvents: Permissions.current.contains(.accessibility)) }
}
