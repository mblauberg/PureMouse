import PureMouseAppSupport
import SwiftUI

/// Pointer's presets, edited in a sheet (also opened from the status menu): the saved speeds as
/// rows with a checkmark on the one the pointer is set to, "+" to save the current speed and "−" to
/// remove the checked preset. Settings apply as they are made, so there is only Done.
struct PresetsSheet: View {
    @Environment(AppModel.self) private var model
    /// The pointer speed now (`PointerPane`'s reading) and the sensor's steps, which a preset snaps to.
    let current: Int
    let steps: [Int]
    /// Applies a preset as the pointer speed.
    let apply: (Int) -> Void

    var body: some View {
        let scope = model.scope
        let presets = model.config.dpiPresets(in: scope)
        let checked = DPIPresets.selected(in: presets, current: current, steps: steps)
        AdvancedSheet(title: "Presets") {
            Section {
                if presets.isEmpty {
                    ContentUnavailableView("No Presets", systemImage: "gauge.with.dots.needle.50percent",
                                           description: Text("Save the current pointer speed with the plus button."))
                }
                ForEach(presets, id: \.self) { preset in
                    row(preset, checked: preset == checked, presets: presets)
                }
            } footer: {
                HStack {
                    Button { add(presets) } label: { glyph("plus.circle") }
                        .disabled(!DPIPresets.canAdd(current, to: presets) || model.readOnly)
                        .accessibilityLabel(DPIPresets.addLabel)
                        .help("Saves the current pointer speed")
                    Button { checked.map { remove($0, from: presets) } } label: { glyph("minus.circle") }
                        .disabled(checked == nil || model.readOnly)
                        .accessibilityLabel(checked.map(DPIPresets.removeLabel) ?? "Remove Preset")
                        .help("Removes the checked preset")
                    if presets.count >= DPIPresets.limit {
                        Text("Up to \(DPIPresets.limit) presets.")
                    }
                    if let note = model.standing(of: [["dpiPresets"]], in: model.scopeTarget).note {
                        Spacer()
                        OverrideLine(note: note, subject: "pointer speed presets")
                    }
                }
                // Borderless, as under System Settings' lists: a section footer draws bordered
                // buttons at mixed sizes (a disabled one full size, an enabled one a mini capsule).
                .buttonStyle(.borderless)
            }
        }
    }

    /// A bare plus or minus is 14 pt wide and, for the minus, 2 pt tall; the circled symbol at
    /// title3 with this padding makes a 21 pt target. The footer's text keeps its own size.
    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.title3).padding(3).contentShape(Rectangle())
    }

    private func row(_ preset: Int, checked: Bool, presets: [Int]) -> some View {
        Button { apply(preset) } label: {
            HStack {
                Text(Format.dpi(preset)).monospacedDigit()
                Spacer()
                if checked { Image(systemName: "checkmark") }
            }
            // A line of text is 16 pt tall; the padding takes the row's target to 20.
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.readOnly)
        .accessibilityLabel(DPIPresets.useLabel(preset))
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityAction(named: "Remove") { remove(preset, from: presets) }
        .contextMenu {
            Button("Remove") { remove(preset, from: presets) }
        }
    }

    private func add(_ presets: [Int]) {
        model.update(in: model.scopeTarget) { $0.setDPIPresets(DPIPresets.adding(current, to: presets), in: model.scope) }
    }

    private func remove(_ preset: Int, from presets: [Int]) {
        guard !model.readOnly else { return }
        model.update(in: model.scopeTarget) { $0.setDPIPresets(DPIPresets.removing(preset, from: presets), in: model.scope) }
    }
}
