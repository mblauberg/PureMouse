import Testing
@testable import PureMouseKit

@Suite struct ControlNamesTests {
    @Test func namesTheControlsTheIssueReports() {
        #expect(ControlNames.name(0x00FD) == "DPI button")
        #expect(ControlNames.name(0x00C3) == "Gesture button")
        #expect(ControlNames.name(0x0052) == "Wheel click")
        #expect(ControlNames.name(0x0050) == "Left button" && ControlNames.name(0x0051) == "Right button")
    }

    @Test func unknownControlsHaveNoName() {
        #expect(ControlNames.name(0x0000) == nil)
        #expect(ControlNames.name(0xFFFF) == nil)
        #expect(ControlNames.name(0x006E) == nil && ControlNames.name(0x0001) == nil)
    }

    @Test func buttonsNineToTwentyFourAreNumbered() {
        #expect(ControlNames.name(0x005E) == "Button 9" && ControlNames.name(0x006D) == "Button 24")
        #expect(ControlNames.name(0x005D) == "Wheel tilt right" && ControlNames.name(0x006E) == nil)
        #expect(ControlNames.name(0x0055) == "Back (Alt+arrow)" && ControlNames.name(0x00CF) == "Forward (multi-platform)")
    }

    @Test func logWordingIsNameThenPaddedHex() {
        // The daemon's capture line: "pressed \(describe) for selection".
        #expect("pressed \(ControlNames.describe(0x00FD)) for selection" == "pressed DPI button (0x00fd) for selection")
        #expect(ControlNames.describe(0x1234) == "0x1234")
        #expect(ControlNames.describe(0x0007) == "0x0007")
    }
}
