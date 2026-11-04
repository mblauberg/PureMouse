import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// The Pointer pane's words and the Presets sheet's list logic.
@Suite struct PointerPresetsTests {
    @Test func thePresetsRowListsThemOrSaysNoneAreSaved() {
        #expect(DPIPresets.summary([]) == "None saved")
        #expect(DPIPresets.summary([1000]) == "1,000 DPI")
        #expect(DPIPresets.summary([1000, 3200]) == "1,000 and 3,200 DPI")
        #expect(DPIPresets.summary([1000, 1650, 3200]) == "1,000, 1,650 and 3,200 DPI")
    }

    @Test func addingKeepsTheListUniqueSortedAndWithinItsLimit() {
        #expect(DPIPresets.adding(1650, to: [1000, 3200]) == [1000, 1650, 3200])
        #expect(DPIPresets.adding(1650, to: [1000, 1650]) == [1000, 1650])
        let full = Array(stride(from: 400, through: 3200, by: 400))
        #expect(full.count == DPIPresets.limit)
        #expect(DPIPresets.newPreset(current: 1650, presets: full, steps: []) == nil)
        #expect(DPIPresets.newPreset(current: 1650, presets: Array(full.dropLast()), steps: []) == 1650)
    }

    @Test func snappingHandlesIntegerExtremes() {
        let steps = [25600, 50, 800]
        #expect(DPIPresets.snap(Int.min, to: steps) == 50)
        #expect(DPIPresets.snap(Int.max, to: steps) == 25600)
        #expect(DPIPresets.snap(Int.min, to: [Int.max, Int.min]) == Int.min)
        #expect(DPIPresets.snap(Int.max, to: [Int.min, Int.max]) == Int.max)
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

    @Test func editsSnapClampMergeAndSort() {
        #expect(DPIPresets.replacing(1000, with: 1580, in: [800, 1000, 3200], steps: [800, 1600, 3200]) == [800, 1600, 3200])
        #expect(DPIPresets.replacing(1000, with: 1600, in: [800, 1000, 1600], steps: [800, 1600]) == [800, 1600])
        #expect(DPIPresets.replacing(1000, with: Int.min, in: [1000, 3200], steps: []) == [50, 3200])
        #expect(DPIPresets.replacing(1000, with: Int.max, in: [800, 1000], steps: []) == [800, 25600])
        #expect(DPIPresets.replacing(1000, with: 0, in: [1000], steps: [0, 200, 800, 30000]) == [200])
        #expect(DPIPresets.replacing(1200, with: 800, in: [1000], steps: []) == [1000])
        // No steps reported: a multiple of 50.
        #expect(DPIPresets.replacing(1000, with: 1234, in: [1000], steps: []) == [1250])
        #expect(DPIPresets.replacing(1000, with: 1224, in: [1000], steps: []) == [1200])
    }

    @Test func newRowsStartAtCurrentThenAdvanceThroughUnsavedSteps() {
        let steps = [800, 1000, 1600, 3200]
        #expect(DPIPresets.newPreset(current: 1550, presets: [800], steps: steps) == 1600)
        #expect(DPIPresets.newPreset(current: 800, presets: [800, 1000], steps: steps) == 1600)
        // From the top step, the nearest unsaved step below.
        #expect(DPIPresets.newPreset(current: 3200, presets: [3200], steps: steps) == 1600)
        #expect(DPIPresets.newPreset(current: 3200, presets: [1600, 3200], steps: steps) == 1000)
        #expect(DPIPresets.newPreset(current: 3200, presets: [800, 1000, 1600, 3200], steps: steps) == nil)
        #expect(DPIPresets.newPreset(current: 1000, presets: [1000], steps: []) == 1050)
        #expect(DPIPresets.newPreset(current: 25600, presets: [25600], steps: []) == 25550)
        // With no steps reported, speeds sit on multiples of 50.
        #expect(DPIPresets.newPreset(current: 1234, presets: [], steps: []) == 1250)
        #expect(DPIPresets.newPreset(current: 1020, presets: [1000, 1050], steps: []) == 1100)
        #expect(DPIPresets.newPreset(current: 800, presets: [800], steps: [3200, 800, 1600, 1000]) == 1000)
        #expect(DPIPresets.newPreset(current: 800, presets: Array(1...8), steps: steps) == nil)
        #expect(DPIPresets.removing(1600, from: [800, 1600, 3200]) == [800, 3200])
    }

    @MainActor @Test func editedPresetsWriteOnlyTheSelectedMouse() throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        try sandbox.write(#"{"dpiPresets":[800,1600],"devices":{"p1234":{"name":"First"},"p5678":{"name":"Second","dpiPresets":[3200]}}}"#)
        let suite = "pm-presets-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(locations: sandbox.locations, defaults: defaults, alert: { _, _ in })
        model.selectMouse("p1234")
        let target = model.scopeTarget
        #expect(target.scope == ConfigScope.device("p1234"))
        let edited = DPIPresets.replacing(800, with: 1000, in: model.config.dpiPresets(in: target.scope), steps: [800, 1000, 1600])
        model.update(in: target) { $0.setDPIPresets(edited, in: target.scope) }
        model.flush()
        let saved = try sandbox.tree()
        #expect(saved.dpiPresets(in: target.scope) == [1000, 1600])
        #expect(saved.dpiPresets(in: .global) == [800, 1600])
        #expect(saved.dpiPresets(in: ConfigScope.device("p5678")!) == [3200])
        // Removing the final row is an explicit empty list for this mouse, not inheritance.
        model.update(in: target) { $0.setDPIPresets([], in: target.scope) }
        model.flush()
        #expect(try sandbox.tree().dpiPresets(in: target.scope).isEmpty)
        #expect(try sandbox.tree().contains(["devices", "p1234", "dpiPresets"]))
    }

    @Test func theEditorCommitsOnlyWhatWasTypedAndTracksTheRowLastEdited() {
        var editor = PresetEditor()
        let steps = [800, 1000, 1600, 3200]
        #expect(editor.commit(800, in: [800, 1600], steps: steps) == nil, "nothing typed, nothing written")
        editor.focus(800)
        editor.draft(800, as: 1100)
        #expect(editor.shown(800) == 1100)
        let commit = editor.commit(800, in: [800, 1600], steps: steps)
        #expect(commit == PresetEditor.Commit(presets: [1000, 1600], row: 1000))
        #expect(editor.shown(800) == 800)
        // The row last edited followed its speed to where it landed.
        #expect(editor.lastEdited == 1000)
        // Merging into an existing row keeps that row as the target.
        editor.draft(1000, as: 1600)
        #expect(editor.commit(1000, in: [1000, 1600], steps: steps)?.presets == [1600])
        #expect(editor.lastEdited == 1600)
    }

    @Test func minusTargetsTheFocusedRowThenTheLastEditedThenTheCheckedOne() {
        var editor = PresetEditor()
        let presets = [800, 1600, 3200]
        #expect(editor.removalTarget(focused: nil, in: presets, checked: 3200) == 3200)
        editor.focus(1600)
        // Tabbing to the button clears focus; the row just edited is still the target.
        #expect(editor.removalTarget(focused: nil, in: presets, checked: 3200) == 1600)
        #expect(editor.removalTarget(focused: 800, in: presets, checked: 3200) == 800)
        // A row that no longer exists is not a target.
        #expect(editor.removalTarget(focused: nil, in: [800, 3200], checked: 3200) == 3200)
        editor.applied()
        #expect(editor.removalTarget(focused: nil, in: presets, checked: 3200) == 3200)
        editor.focus(800)
        editor.draft(800, as: 1000)
        #expect(editor.remove(800, from: presets) == [1600, 3200])
        #expect(editor.lastEdited == nil)
        #expect(editor.shown(800) == 800, "its draft is gone")
    }

    @Test func pointerUsesPlainWordsAndLinksToMouseSettings() {
        #expect(PointerWords.title == "Pointer speed")
        #expect([PointerWords.slow, PointerWords.fast] == ["Slow", "Fast"])
        #expect(PointerWords.help == "Faster moves the pointer further for the same movement.")
        #expect(PointerWords.footer == "Tracking speed in System Settings applies on top.")
        #expect(PointerWords.openMouseSettings == "Open Mouse Settings")
        #expect(URL(string: PointerWords.mouseSettingsURL)?.scheme == "x-apple.systempreferences")
        #expect(PointerWords.mouseSettingsURL.hasSuffix("com.apple.Mouse-Settings.extension"))
        #expect(PointerWords.exactLabel != PointerWords.title, "the field and the slider sound different")
    }

    @Test func disclosuresDoNotAnimateUnderReduceMotion() {
        #expect(DisclosureMotion.animates(reduceMotion: false))
        #expect(!DisclosureMotion.animates(reduceMotion: true))
    }
}
