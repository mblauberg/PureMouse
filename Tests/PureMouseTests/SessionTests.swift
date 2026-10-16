import Testing
@testable import puremouse

@MainActor
struct SessionActionTests {
    @Test func cancellingTailCancelsAnEarlierActionWaitingForTransport() async {
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        var releaseTransport: CheckedContinuation<Void, Never>?
        var touchedDevice = false
        var earlierWasCancelled = false
        let first = Session.chainedAction(after: nil) {
            await withTaskCancellationHandler {
                // Like HIDPPDevice.acquire(), this wait itself is not cancellation-aware.
                await withCheckedContinuation { continuation in
                    releaseTransport = continuation
                    started.continuation.yield()
                }
                earlierWasCancelled = Task.isCancelled
                // HIDPPDevice.send checks cancellation before writing to the endpoint.
                if !Task.isCancelled { touchedDevice = true }
            } onCancel: {
                cancelled.continuation.yield()
            }
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let tail = Session.chainedAction(after: first) { touchedDevice = true }
        tail.cancel()
        // Bound the regression failure: a broken chain must fail instead of hanging the suite.
        let observedCancellation = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var cancellations = cancelled.stream.makeAsyncIterator()
                return await cancellations.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
        #expect(observedCancellation)
        releaseTransport?.resume()
        await tail.value
        #expect(earlierWasCancelled && !touchedDevice)
    }
}
