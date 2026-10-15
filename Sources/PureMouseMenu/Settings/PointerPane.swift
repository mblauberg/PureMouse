import SwiftUI

struct PointerPane: View {
    @Environment(AppModel.self) private var model
    @State private var typed: Int?
    @State private var reading = DPIReading()

    /// The sensor's accepted values; without a mouse, the MX Master 3S's 200–8000 in steps of 50.
    private var steps: [Int] {
        let reported = model.primaryDevice?.dpiSteps ?? []
        return reported.isEmpty ? Array(stride(from: 200, through: 8000, by: 50)) : reported
    }

    private var configured: Int? { model.config.int(["dpi"]) }
    private var live: Int? { model.liveDevice?.dpi }
    private var current: Int { reading.current(live: live, configured: configured) }

    var body: some View {
        let steps = steps
        let presets = model.config.dpiPresets
        PaneForm {
            PaneBanners()
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("DPI").foregroundStyle(.secondary).accessibilityHidden(true)
                            TextField("DPI", value: Binding(get: { typed ?? current }, set: { typed = $0 }),
                                      format: .number.grouping(.automatic))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .labelsHidden()
                                .onSubmit { commitTyped(steps) }
                                .accessibilityLabel("Resolution in DPI")
                        }
                    } label: {
                        Text("Resolution")
                        Text(configured == nil
                             ? "Higher moves the pointer further for the same hand movement. Mouse default."
                             : "Higher moves the pointer further for the same hand movement.")
                    }
                    EndLabeledSlider(title: "Resolution",
                                     value: Binding(get: { Double(DPIReading.index(of: current, in: steps)) },
                                                    set: { DPIReading.step(at: $0, in: steps).map { setDPI($0, debounce: true) } }),
                                     range: 0...Double(max(steps.count - 1, 1)),
                                     low: Format.number(steps.first ?? 200), high: Format.number(steps.last ?? 8000))
                    // A sensor with a single setting has nothing to slide between.
                    .disabled(steps.count < 2)
                    .accessibilityValue(Format.dpi(current))
                    Text(model.devices.count > 1
                         ? "Steps follow \(model.primaryDevice?.name ?? "this mouse")'s sensor. Applies to all connected mice. Tracking speed in System Settings still applies on top."
                         : "Steps follow this mouse's sensor. Tracking speed in System Settings still applies on top.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent {} label: {
                    RowLabel("Presets", help: "Shown in the menu bar, and used by the Cycle Pointer Speed button action.")
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        PresetChip(dpi: preset, selected: DPIPresets.snap(preset, to: steps) == current) {
                            setDPI(preset)
                        } remove: {
                            model.update { $0.dpiPresets = DPIPresets.removing(preset, from: presets) }
                        }
                    }
                    if presets.isEmpty {
                        Text("No presets yet").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Add Current") {
                        model.update { $0.dpiPresets = DPIPresets.adding(current, to: presets) }
                    }
                    .disabled(presets.contains(current) || presets.count >= DPIPresets.limit)
                }
            } footer: {
                FooterButton("Restore Defaults") {
                    typed = nil
                    reading.clear()
                    model.update {
                        $0.set(nil, at: ["dpi"])
                        $0.set(nil, at: ["dpiPresets"])
                    }
                }
            }
            .disabled(model.readOnly)
        }
        .onChange(of: live) { reading.reported(live, steps: steps) }
        .onChange(of: model.writeError) { if model.writeError != nil { reading.clear() } }
    }

    private func setDPI(_ dpi: Int, debounce: Bool = false) {
        typed = nil
        guard !model.readOnly else { return }
        reading.request(dpi)
        model.setDPI(dpi, debounce: debounce)
    }

    private func commitTyped(_ steps: [Int]) {
        guard let typed else { return }
        setDPI(DPIPresets.snap(typed, to: steps))
    }
}

private struct PresetChip: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }
    let dpi: Int
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(Format.number(dpi), action: select)
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(Format.dpi(dpi))")
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the \(Format.dpi(dpi)) preset")
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        // Dark mode needs a stronger tint and an edge to stand off the grouped background.
        .background(Color.accentColor.opacity(selected ? (dark ? 0.42 : 0.22) : (dark ? 0.26 : 0.1)), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(selected ? (dark ? 0.9 : 0.5) : (dark ? 0.45 : 0)),
                                   lineWidth: selected ? 1 : 0.5)
        }
    }
}
