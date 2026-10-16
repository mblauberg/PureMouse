import Testing
@testable import puremouse

private struct Failure: Error, Equatable { let item: Int }

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async { await withCheckedContinuation { continuation = $0 } }

    func open() {
        continuation?.resume()
        continuation = nil
    }

    /// Lets queued tasks run until `condition` holds.
    static func spin(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}

@MainActor
@Suite struct SerialChainTests {
    @Test func runsInOrder() async {
        let chain = SerialChain()
        var log: [Int] = []
        for i in 0..<5 { chain.enqueue { await Task.yield(); log.append(i) } }
        await chain.drain()
        #expect(log == [0, 1, 2, 3, 4])
    }

    /// A reload while a handoff awaits the mouse: the old session closes (cancelling its chain)
    /// and the replacement's writes wait for it, so no old write can land after the new ones.
    @Test func replacementWaitsForTheCancelledPredecessor() async {
        let old = SerialChain()
        let gate = Gate()
        var log: [String] = []
        old.enqueue {
            defer { log.append("old ended") }
            await gate.wait()  // e.g. reading the wheel multiplier
            try Task.checkCancellation()
            log.append("old diverted the wheels")
        }
        old.enqueue { log.append("old queued write") }
        await Gate.spin { gate.isWaiting }

        let replacement = SerialChain(after: old.end)
        replacement.enqueue { log.append("replacement set the wheels native") }
        old.cancel()
        await Task.yield()
        #expect(log.isEmpty)  // still waiting for the old body
        gate.open()
        await replacement.drain()
        #expect(log == ["old ended", "replacement set the wheels native"])
    }

    /// Closing a session cancels its device actions: one waiting for the endpoint (inside
    /// `HIDPPDevice.acquire()`, which is not cancellation-aware) must see it before it sends, and
    /// nothing queued behind it may run.
    @Test func cancelReachesABodyWaitingForTransport() async {
        let chain = SerialChain()
        let gate = Gate()
        var earlierWasCancelled = false
        var touchedDevice = false
        chain.enqueue {
            await gate.wait()
            earlierWasCancelled = Task.isCancelled
            // HIDPPDevice.send checks cancellation before writing to the endpoint.
            if !Task.isCancelled { touchedDevice = true }
        }
        chain.enqueue { touchedDevice = true }
        await Gate.spin { gate.isWaiting }
        chain.cancel()
        gate.open()
        await chain.drain()
        #expect(earlierWasCancelled && !touchedDevice)
    }

    @Test func failuresAreReported() async {
        let chain = SerialChain()
        var failures: [Int] = []
        chain.enqueue({ throw Failure(item: 1) }, onFailure: { failures.append(($0 as? Failure)?.item ?? -1) })
        chain.enqueue({}, onFailure: { _ in failures.append(-2) })
        await chain.drain()
        #expect(failures == [1])
    }
}

@MainActor
@Suite struct IndependentlyTests {
    /// One input that fails to be handed back (say the main wheel times out) must not stop the
    /// others (the thumb wheel, the other controls).
    @Test func triesEveryItemAndThrowsAFailure() async {
        var tried: [Int] = []
        var released: Set<Int> = [1, 2, 3, 4]
        await #expect(throws: Failure(item: 3)) {
            try await Independently.each([1, 2, 3, 4], stopsOn: { _ in false }) { item in
                tried.append(item)
                if item == 2 || item == 3 { throw Failure(item: item) }
                released.remove(item)
            }
        }
        #expect(tried == [1, 2, 3, 4])
        #expect(released == [2, 3])  // only the failures are still owed a release
    }

    @Test func stopsAtOnceWhenTheSessionEnds() async {
        var tried: [Int] = []
        await #expect(throws: CancellationError.self) {
            try await Independently.each([1, 2, 3], stopsOn: { $0 is CancellationError }) { item in
                tried.append(item)
                if item == 2 { throw CancellationError() }
            }
        }
        #expect(tried == [1, 2])
    }

    @Test func succeedsWhenEveryItemDoes() async throws {
        var tried: [Int] = []
        try await Independently.each([1, 2], stopsOn: { _ in true }) { tried.append($0) }
        #expect(tried == [1, 2])
    }
}
