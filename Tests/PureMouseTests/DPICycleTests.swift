import Testing
@testable import puremouse
import PureMouseKit

@Suite struct DPICycleTests {
    @Test func stepsUpAndWraps() {
        let presets = [1600, 800, 3200]
        #expect(Config.nextPreset(presets, after: 800) == 1600)
        #expect(Config.nextPreset(presets, after: 1600) == 3200)
        #expect(Config.nextPreset(presets, after: 3200) == 800)
    }

    @Test func fromAnUnlistedDPIGoesToTheNextAbove() {
        #expect(Config.nextPreset([800, 1600], after: 1000) == 1600)
        #expect(Config.nextPreset([800, 1600], after: 5000) == 800)
        #expect(Config.nextPreset([800, 800], after: 800) == 800)
        #expect(Config.nextPreset([], after: 800) == nil)
    }
}
