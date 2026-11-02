/// Thrown by `eventually` when its condition never held.
public struct EventuallyTimedOut: Error, CustomStringConvertible {
    public var description: String { "condition did not hold within the deadline" }
}

/// Yields to other main-actor work until `condition` holds, failing after `deadline`.
@MainActor
public func eventually(within deadline: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + deadline
    while !condition() {
        guard ContinuousClock.now < end else { throw EventuallyTimedOut() }
        await Task.yield()
    }
}
