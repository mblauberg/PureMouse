/// Live defaults preserve the daemon's permission checks and retry cadence. Tests can exercise
/// device behaviour without event-posting permission or five-second retry sleeps.
struct SessionEnvironment {
    var canPostEvents: Bool
    var configureRetryDelay: Duration = .seconds(5)
    var now: () -> ContinuousClock.Instant = { .now }
    /// The scroll engine's frame clock and where it posts: a test supplies its own of each.
    var frameClock: @MainActor () -> FrameClock = { FrameClock() }
    var postScroll: (Int, Int) -> Void = { ScrollEvent.post(dx: $0, dy: $1) }

    static var live: Self { Self(canPostEvents: Permissions.current.contains(.accessibility)) }
}
