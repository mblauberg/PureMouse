import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

// The action picker's entries (`PickerEntry`, in the Settings view code).

@Test func anAppPickerOffersSameAsEverywhereInsteadOfDefault() {
    let entries = PickerEntry.all(allowsDefault: false, allowsGesture: true, inherited: ActionButton.inherited(.standard, everywhere: "Mission Control"))
    #expect(entries.first?.label == "Same as Everywhere")
    #expect(entries.first?.detail == "(Mission Control)")
    #expect(entries.first?.matches(.standard) == true)
    #expect(!entries.contains { $0.id == "default" })
}

@Test func thePickerListsEveryHapticWaveformInWords() {
    let entries = PickerEntry.all(allowsDefault: true, allowsGesture: true)
        .filter { $0.group == ActionCatalog.hapticGroup }
    #expect(entries.map(\.kind) == HapticWaveform.allCases.map { .set(.haptic($0.rawValue)) })
    #expect(entries.allSatisfy { $0.symbol != nil })
    #expect(ActionCatalog.hapticLabel(for: "sharpStateChange") == "Sharp State Change")
    #expect(ActionCatalog.hapticLabel(for: "happyAlert") == "Happy Alert")
    #expect(ActionCatalog.hapticLabel(for: "boxBreathing") == "Box Breathing")
    #expect(ButtonAction.haptic("happyAlert").label == "Haptic: Happy Alert")
    #expect(ActionCatalog.hapticGroup.contains("MX Master 4"))
}
