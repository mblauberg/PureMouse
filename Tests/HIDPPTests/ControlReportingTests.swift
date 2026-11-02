import HIDPP
import Testing

struct ControlReportingTests {
    @Test func reportingDecodesTemporaryPersistentAndRawFlags() {
        let r = ReprogControls.parseReporting([0, 0x56, 0x15, 0, 0, 0])
        #expect(r?.cid == 0x56)
        #expect(r?.diverted == true && r?.persistent == true && r?.rawXY == true)
        let native = ReprogControls.parseReporting([0, 0x56, 0x22])
        #expect(native?.diverted == false && native?.persistent == false && native?.rawXY == false)
        #expect(ReprogControls.parseReporting([0, 0x56]) == nil)
    }
}
