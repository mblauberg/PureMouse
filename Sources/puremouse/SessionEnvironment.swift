/// Live defaults preserve the daemon's permission checks and retry cadence. Tests can exercise
/// device behaviour without event-posting permission or five-second retry sleeps.
struct SessionEnvironment {
    var canPostEvents: Bool
    var configureRetryDelay: Duration = .seconds(5)
    var now: () -> ContinuousClock.Instant = { .now }

    static var live: Self { Self(canPostEvents: Permissions.current.contains(.accessibility)) }
}
