import Testing
@testable import puremouse

@Suite struct BackoffTests {
    @Test func adoptionMatchesTheReceiverSlotSchedule() {
        #expect(Backoff.adoption.delays == [1, 2, 4, 8].map { .seconds($0) })
        #expect(Backoff.bluetooth.delays.starts(with: Backoff.adoption.delays))
        #expect(Backoff.bluetooth.delays.dropFirst(4).allSatisfy { $0 == .seconds(60) })
    }

    @Test func triesAfterEachDelayThenStops() async {
        var slept: [Duration] = [], attempts = 0
        await Backoff.adoption.retry(sleep: { slept.append($0) }) {
            attempts += 1
            return true  // never answers
        }
        #expect(slept == Backoff.adoption.delays)
        #expect(attempts == 4)
    }

    @Test func stopsOnceThereIsNothingMoreToTry() async {
        var slept: [Duration] = [], attempts = 0
        await Backoff.adoption.retry(sleep: { slept.append($0) }) {
            attempts += 1
            return attempts < 2  // adopted, paused or gone on the second try
        }
        #expect(slept == [.seconds(1), .seconds(2)])
        #expect(attempts == 2)
    }

    @Test func cancelledSleepEndsWithoutAnAttempt() async {
        var attempts = 0
        await Backoff.adoption.retry(sleep: { _ in throw CancellationError() }) {
            attempts += 1
            return true
        }
        #expect(attempts == 0)
    }

    @Test func cancelledTaskStopsAfterItsSleep() async {
        let task = Task {
            var attempts = 0
            await Backoff.adoption.retry(sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } }) {
                attempts += 1
                return true
            }
            return attempts
        }
        #expect(await task.value == 0)
    }
}
