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
    }

    @Test func newRowsStartAtCurrentThenAdvanceThroughUnsavedSteps() {
        let steps = [800, 1000, 1600, 3200]
        #expect(DPIPresets.newPreset(current: 1550, presets: [800], steps: steps) == 1600)
        #expect(DPIPresets.newPreset(current: 800, presets: [800, 1000], steps: steps) == 1600)
        #expect(DPIPresets.newPreset(current: 3200, presets: [3200], steps: steps) == nil)
        #expect(DPIPresets.newPreset(current: 1000, presets: [1000], steps: []) == 1050)
        #expect(DPIPresets.newPreset(current: 25600, presets: [25600], steps: []) == nil)
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

    /// Source contracts cover UI wiring without launching Settings on the working Mac.
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/PureMouseSettingsUI/" + name + ".swift"), encoding: .utf8)
    }

    @Test func pointerUsesPlainWordsAndLinksToMouseSettings() throws {
        let pane = try source("PointerPane")
        for text in [#"title: "Pointer speed""#, #"low: "Slow", high: "Fast""#, "showsReadout: false",
                     "Faster moves the pointer further for the same movement.",
                     "Tracking speed in System Settings applies on top.", "Open Mouse Settings",
                     "x-apple.systempreferences:com.apple.Mouse-Settings.extension"] {
            #expect(pane.contains(text), "Missing \(text)")
        }
        #expect(pane.contains(#".accessibilityLabel("Exact pointer speed")"#))
        #expect(pane.contains("if !exactValue"))
        #expect(pane.contains("Text(reading.readout(live: live, configured: configured))"))
        let components = try source("Components")
        #expect(components.contains("if showsReadout"))
    }

    @Test func presetEditsCommitOnReturnAndFocusLossInTheSelectedScope() throws {
        let sheet = try source("PresetsSheet")
        for wiring in [".onSubmit { commit(preset) }", ".onChange(of: focused)", "if let old { commit(old) }",
                       "let removable = focused ?? checked", "focused = preset", "let target = model.scopeTarget",
                       "model.update(in: target)", "setDPIPresets(presets, in: target.scope)",
                       "DPIPresets.replacing", "DPIPresets.newPreset", "#if DEBUG",
                       "PUREMOUSE_DEV_PRESET_EDIT"] {
            #expect(sheet.contains(wiring), "Missing \(wiring)")
        }
    }

    @Test func disclosuresRespectMotionAndExposeANativeDisclosure() throws {
        let components = try source("Components")
        #expect(components.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(components.contains("withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2))"))
        #expect(components.contains(".accessibilityRepresentation"))
        #expect(components.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        #expect(components.contains(".transaction { if reduceMotion { $0.animation = nil } }"))
    }
}
