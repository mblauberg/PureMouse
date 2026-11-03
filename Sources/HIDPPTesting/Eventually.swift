/// Thrown by `eventually` when its condition never held.
public struct EventuallyTimedOut: Error, CustomStringConvertible {
    public var description: String { "condition did not hold within the deadline" }
}

/// Yields to other main-actor work until `condition` holds, failing after `deadline`.
///
/// The deadline is how long the condition may take, not how long the main actor is busy: Swift
/// Testing runs every `@MainActor` test in one process, and a yield queues behind all of them, so
/// a wait started while heavy UI tests are queued can be suspended for seconds without its
/// condition being any slower. Time spent suspended in a yield past `queueGrace` therefore does
/// not count against the deadline; time the condition's own work takes (timers, retries) still does.
@MainActor
public func eventually(within deadline: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    var end = clock.now + deadline
    while !condition() {
        let before = clock.now
        guard before < end else { throw EventuallyTimedOut() }
        await Task.yield()
        let suspended = clock.now - before
        if suspended > queueGrace { end += suspended - queueGrace }
    }
}

/// A yield that resumes within this long was not held up by other main-actor work.
private let queueGrace: Duration = .milliseconds(5)
