import Testing
@testable import PureMouseAppSupport

// The Pointer pane's words and the Presets sheet's list logic.

@Test func thePresetsRowListsThemOrSaysNoneAreSaved() {
    #expect(DPIPresets.summary([]) == "None saved")
    #expect(DPIPresets.summary([1000]) == "1,000 DPI")
    #expect(DPIPresets.summary([1000, 3200]) == "1,000 and 3,200 DPI")
    #expect(DPIPresets.summary([1000, 1650, 3200]) == "1,000, 1,650 and 3,200 DPI")
}

@Test func addIsOfferedUntilTheSpeedIsSavedOrTheListIsFull() {
    #expect(DPIPresets.canAdd(1650, to: []))
    #expect(!DPIPresets.canAdd(1650, to: [1000, 1650]))
    let full = Array(stride(from: 400, through: 3200, by: 400))
    #expect(full.count == DPIPresets.limit)
    #expect(!DPIPresets.canAdd(1650, to: full))
    #expect(DPIPresets.canAdd(1650, to: Array(full.dropLast())))
}

@Test func theCheckedPresetIsTheOneTheSensorRunsAt() {
    let steps = [800, 1000, 1600, 1650, 3200]
    #expect(DPIPresets.selected(in: [1000, 1650], current: 1650, steps: steps) == 1650)
    // A preset off the sensor's list is checked at its nearest step.
    #expect(DPIPresets.selected(in: [1640], current: 1650, steps: steps) == 1640)
    #expect(DPIPresets.selected(in: [1000, 3200], current: 1650, steps: steps) == nil)
    #expect(DPIPresets.selected(in: [], current: 1650, steps: steps) == nil)
}

@Test func theSheetsControlsHaveDistinctSpokenLabels() {
    #expect(DPIPresets.useLabel(1650) == "Use 1,650 DPI")
    #expect(DPIPresets.removeLabel(1650) == "Remove the 1,650 DPI preset")
    #expect(DPIPresets.addLabel == "Add Preset")
    #expect(Set([DPIPresets.useLabel(1650), DPIPresets.removeLabel(1650), DPIPresets.addLabel]).count == 3)
}

@Test func withNothingReportedOrConfiguredTheReadoutIsAnEstimate() {
    var reading = DPIReading()
    #expect(reading.isEstimate(live: nil, configured: nil))
    #expect(reading.readout(live: nil, configured: nil) == "About 1,000 DPI")
    #expect(reading.readout(live: nil, configured: 1650) == "1,650 DPI")
    #expect(reading.readout(live: 3200, configured: nil) == "3,200 DPI")
    // A change made here is the speed, not a guess.
    reading.request(800)
    #expect(reading.readout(live: nil, configured: nil) == "800 DPI")
}

@Test func controlsAreTitledByKitsNamesElseTheirHexId() {
    #expect(NamedButton.title(forKey: "gesture") == "Gesture button")
    #expect(NamedButton.title(forKey: "0x00fd") == "DPI button")
    #expect(NamedButton.title(forKey: "0x00FD") == "DPI button")
    #expect(NamedButton.title(forKey: "0x1234") == "Button 4660", "an unnamed control is a plain button, never a hex ID")
    #expect(NamedButton.title(forKey: "0x00e5") == "Button 229")
    #expect(NamedButton.title(forKey: "nonsense") == "Other button")
}
