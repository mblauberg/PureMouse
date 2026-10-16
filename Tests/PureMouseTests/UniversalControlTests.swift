import Testing
@testable import puremouse

@Suite struct UniversalControlTests {
    @Test func stateBitsAsObserved() {
        // Crossing over (0x2), keyboard following (0x3), coming back (0x1), home (0x0).
        let observed: [(UInt64, pointer: Bool, keyboard: Bool)] = [
            (0x0, false, false), (0x2, true, false), (0x3, true, true), (0x1, false, true),
        ]
        for (raw, pointer, keyboard) in observed {
            let state = UniversalControlState(raw: raw)
            #expect(state.pointerAway == pointer)
            #expect(state.keyboardAway == keyboard)
        }
        #expect(UniversalControlState(raw: 0xFF02).pointerAway)  // other bits do not matter
    }

    @Test func handingOffNeedsThePointerAwayAndTheSetting() {
        #expect(Handoff.handingOff(pointerAway: true, enabled: true))
        #expect(!Handoff.handingOff(pointerAway: true, enabled: false))
        #expect(!Handoff.handingOff(pointerAway: false, enabled: true))
    }

    @Test func awayDivertsNoControls() {
        let bound: Set<UInt16> = [0x53, 0x56]
        #expect(Handoff.wantedControls(bound: bound, capturing: nil, away: false) == bound)
        #expect(Handoff.wantedControls(bound: bound, capturing: [0xC4], away: false) == [0x53, 0x56, 0xC4])
        #expect(Handoff.wantedControls(bound: bound, capturing: [0xC4], away: true).isEmpty)
    }

    @Test func awayLeavesTheWheelsNative() {
        #expect(Handoff.wheelsDiverted(scrolling: true, accessibility: true, away: false))
        #expect(!Handoff.wheelsDiverted(scrolling: true, accessibility: true, away: true))
        #expect(!Handoff.wheelsDiverted(scrolling: true, accessibility: false, away: false))
        #expect(!Handoff.wheelsDiverted(scrolling: false, accessibility: true, away: false))
    }
}
