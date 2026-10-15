import Testing
@testable import puremouse

@Suite struct PauseGateTests {
    @Test func resumeWaitsForTheRestore() {
        var gate = PauseGate()
        #expect(gate.allowsAdoption)
        let first = gate.pause()
        #expect(!gate.allowsAdoption)
        let adoptOnResume = gate.resume()
        #expect(!adoptOnResume)  // still restoring: not yet
        #expect(!gate.paused && !gate.allowsAdoption)
        let adoptOnRestored = gate.restored(first)
        #expect(adoptOnRestored)  // the restore adopts
        #expect(gate.allowsAdoption)
    }

    @Test func resumeAfterTheRestoreAdoptsAtOnce() {
        var gate = PauseGate()
        let first = gate.pause()
        let adoptOnRestored = gate.restored(first)
        #expect(!adoptOnRestored)  // still paused
        #expect(!gate.allowsAdoption)
        let adoptOnResume = gate.resume()
        #expect(adoptOnResume)
        #expect(gate.allowsAdoption)
    }

    @Test func onlyTheLatestPauseEndsTheRestore() {
        var gate = PauseGate()
        let first = gate.pause()
        _ = gate.resume()
        let second = gate.pause()
        _ = gate.resume()
        let staleRestore = gate.restored(first)
        #expect(!staleRestore)
        #expect(!gate.allowsAdoption)
        let latestRestore = gate.restored(second)
        #expect(latestRestore)
        #expect(gate.allowsAdoption)
    }
}
