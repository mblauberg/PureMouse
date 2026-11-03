import PureMouseAppSupport
import SwiftUI

/// Saved speeds edit in place. Return and focus loss commit; the checkmark button applies a speed.
struct PresetsSheet: View {
    @Environment(AppModel.self) private var model
    @State private var drafts: [Int: Int] = [:]
    @FocusState private var focused: Int?
    /// The pointer speed now (`PointerPane`'s reading) and the sensor's steps.
    let current: Int
    let steps: [Int]
    let apply: (Int) -> Void

    var body: some View {
        let presets = model.config.dpiPresets(in: model.scope)
        let checked = DPIPresets.selected(in: presets, current: current, steps: steps)
        let removable = focused ?? checked
        AdvancedSheet(title: "Presets") {
            Section {
                if presets.isEmpty {
                    ContentUnavailableView("No Presets", systemImage: "gauge.with.dots.needle.50percent",
                                           description: Text("Add a pointer speed with the plus button."))
                }
                ForEach(presets, id: \.self) { preset in
                    row(preset, checked: preset == checked)
                }
            } footer: {
                HStack {
                    Button { add() } label: { glyph("plus.circle") }
                        .disabled(DPIPresets.newPreset(current: current, presets: presets, steps: steps) == nil || model.readOnly)
                        .accessibilityLabel(DPIPresets.addLabel)
                        .help("Adds a speed you can edit")
                    Button { removable.map { remove($0) } } label: { glyph("minus.circle") }
                        .disabled(presets.isEmpty || removable == nil || model.readOnly)
                        .accessibilityLabel(removable.map(DPIPresets.removeLabel) ?? "Remove Preset")
                        .help("Removes the focused preset, or the checked preset")
                    if presets.count >= DPIPresets.limit {
                        Text("Up to \(DPIPresets.limit) presets.")
                    }
                    if let note = model.standing(of: [["dpiPresets"]], in: model.scopeTarget).note {
                        Spacer()
                        OverrideLine(note: note, subject: "pointer speed presets")
                    }
                }
                // System Settings' list footer uses borderless buttons at a consistent size.
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: focused) { old, _ in
            if let old { commit(old) }
        }
        .onDisappear { if let focused { commit(focused) } }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["PUREMOUSE_DEV_PRESET_EDIT"] == "1" {
                if let first = presets.first { focused = first } else { add() }
            }
        }
        #endif
    }

    /// Circled symbols at title3 plus padding give the footer buttons a target over 20 pt.
    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.title3).padding(3).contentShape(Rectangle())
    }

    private func row(_ preset: Int, checked: Bool) -> some View {
        HStack {
            TextField("Preset", value: Binding(get: { drafts[preset] ?? preset },
                                               set: { drafts[preset] = $0 }),
                      format: .number.grouping(.automatic))
                .textFieldStyle(.plain)
                // A plain field's line is 16 pt; padding gives it the 20 pt minimum target.
                .padding(.vertical, 2)
                .monospacedDigit()
                .focused($focused, equals: preset)
                .onSubmit { commit(preset) }
                .accessibilityLabel("Edit \(Format.dpi(preset)) preset")
            Text("DPI").foregroundStyle(.secondary).accessibilityHidden(true)
            Button { apply(preset) } label: {
                glyph(checked ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(DPIPresets.useLabel(preset))
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
        .disabled(model.readOnly)
        .accessibilityAction(named: "Remove") { remove(preset) }
        .contextMenu { Button("Remove") { remove(preset) } }
    }

    private func commit(_ preset: Int) {
        guard !model.readOnly, let value = drafts.removeValue(forKey: preset) else { return }
        let presets = model.config.dpiPresets(in: model.scope)
        let updated = DPIPresets.replacing(preset, with: value, in: presets, steps: steps)
        save(updated)
        // Editing can reorder or merge rows; keep Return's focus at the committed speed.
        if focused == preset {
            focused = DPIPresets.replacing(preset, with: value, in: [preset], steps: steps).first
        }
    }

    private func add() {
        guard !model.readOnly else { return }
        if let focused { commit(focused) }
        let presets = model.config.dpiPresets(in: model.scope)
        guard let preset = DPIPresets.newPreset(current: current, presets: presets, steps: steps) else { return }
        save(DPIPresets.adding(preset, to: presets))
        focused = preset
    }

    private func remove(_ preset: Int) {
        guard !model.readOnly else { return }
        drafts[preset] = nil
        if focused == preset { focused = nil }
        save(DPIPresets.removing(preset, from: model.config.dpiPresets(in: model.scope)))
    }

    private func save(_ presets: [Int]) {
        let target = model.scopeTarget
        model.update(in: target) { $0.setDPIPresets(presets, in: target.scope) }
    }
}
