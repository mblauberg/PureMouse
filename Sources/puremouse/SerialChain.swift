/// Runs async bodies one at a time, each starting after the one enqueued before it has ended.
/// A chain can begin after another's end (`init(after:)`), so a replacement session's diversion
/// changes wait for its predecessor's; `cancel` stops every body not yet ended at its next
/// cancellation check (a HID++ request queued behind others never goes out once cancelled).
@MainActor
final class SerialChain {
    private var tail: Task<Void, Never>?
    private var running: [Int: Task<Void, Error>] = [:]
    private var nextID = 0

    init(after predecessor: Task<Void, Never>? = nil) {
        tail = predecessor
    }

    /// Ends once everything enqueued so far has ended: what a successor chain starts after.
    var end: Task<Void, Never>? { tail }

    /// Queues `body`; `onFailure` gets its error, if any, once it has ended.
    @discardableResult
    func enqueue(_ body: @escaping @MainActor () async throws -> Void,
                 onFailure: @escaping @MainActor (Error) -> Void = { _ in }) -> Task<Void, Error> {
        let id = nextID
        nextID += 1
        let work = Task { [previous = tail] in
            await previous?.value
            try Task.checkCancellation()
            try await body()
        }
        running[id] = work
        tail = Task {
            let result = await work.result
            running[id] = nil
            if case .failure(let error) = result { onFailure(error) }
        }
        return work
    }

    /// Cancels every body not yet ended, including those still waiting their turn.
    func cancel() {
        running.values.forEach { $0.cancel() }
    }

    /// Waits for everything enqueued so far to end.
    func drain() async {
        await tail?.value
    }
}

/// Steps that must each be tried even if another fails, such as handing several inputs back.
enum Independently {
    /// Calls `body` for every item, in order, whatever earlier ones threw, then throws the last
    /// failure. An error `stop` accepts (cancellation, a finished session) ends it at once.
    @MainActor
    static func each<T>(_ items: [T], stopsOn stop: (Error) -> Bool,
                        _ body: @MainActor (T) async throws -> Void) async throws {
        var failure: Error?
        for item in items {
            do {
                try await body(item)
            } catch {
                if stop(error) { throw error }
                failure = error
            }
        }
        if let failure { throw failure }
    }
}
