import PureMouseAppSupport
import SwiftUI

struct PointerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    @State private var typed: Int?
    @State private var exactValue = false
    @State private var reading = DPIReading()

    /// What the mouse has reported of the sensor's accepted values; empty before it has.
    private var reportedSteps: [Int] { model.primaryDevice?.dpiSteps ?? [] }

    /// The slider's steps: the mouse's, else the MX Master 3S's 200–8000 in steps of 50 until it reports.
    private var steps: [Int] {
        reportedSteps.isEmpty ? Array(stride(from: 200, through: 8000, by: 50)) : reportedSteps
    }

    private var configured: Int? { model.config.int(["dpi"]) }
    private var live: Int? { model.liveDevice?.dpi }
    private var current: Int { reading.current(live: live, configured: configured) }
    private var estimate: Bool { reading.isEstimate(live: live, configured: configured) }

    var body: some View {
        let steps = steps
        let reported = !reportedSteps.isEmpty
        let presets = model.config.dpiPresets
        let layout = PointerLayout(config: model.config, devices: model.capabilityDevices)
        PaneForm {
            PaneBanners()
            Section {
                if layout.showsRows {
                    ValueSlider(title: "Pointer Speed", spokenTitle: "Pointer speed",
                                help: "Higher moves the pointer further for the same hand movement. Available speeds depend on your mouse.",
                                value: Binding(get: { Double(DPIReading.index(of: current, in: steps)) },
                                               set: { DPIReading.step(at: $0, in: steps).map { setDPI($0, debounce: true) } }),
                                range: 0...Double(max(steps.count - 1, 1)),
                                low: reported ? Format.number(steps.first ?? 0) : "",
                                high: reported ? Format.number(steps.last ?? 0) : "",
                                format: { _ in reading.readout(live: live, configured: configured) },
                                availability: layout.availability, mouseDefault: estimate)
                        // A sensor with a single setting has nothing to slide between.
                        .disabled(steps.count < 2)
                    LabeledContent {} label: {
                        DisclosureLabel(title: "Exact value", isExpanded: $exactValue)
                    }
                    if exactValue {
                        LabeledContent {
                            HStack(spacing: 4) {
                                TextField("Pointer speed", value: Binding(get: { typed ?? current }, set: { typed = $0 }),
                                          format: .number.grouping(.automatic))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .labelsHidden()
                                    .onSubmit { commitTyped(steps) }
                                    .accessibilityLabel("Pointer speed")
                                Text("DPI").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        } label: {
                            Text("Pointer speed")
                        }
                        .disclosedRow()
                    }
                    LabeledContent {
                        Button("Edit Presets…") { settings?.sheet = .presets }
                    } label: {
                        RowLabel("Presets", help: DPIPresets.summary(presets), availability: layout.availability)
                    }
                } else {
                    // Nothing else on the pane applies, so say why it is bare.
                    LabeledContent {} label: {
                        RowLabel("Pointer Speed", help: ControlAvailability.unsupportedCaption)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.devices.count > 1
                         ? "The Tracking speed setting in System Settings applies on top. Applies to every connected mouse."
                         : "The Tracking speed setting in System Settings applies on top.")
                    PaneFooter(restoreDefaults: {
                        typed = nil
                        reading.clear()
                        model.update {
                            $0.set(nil, at: ["dpi"])
                            $0.set(nil, at: ["dpiPresets"])
                        }
                    }, restoreMessage: "Pointer speed and presets return to the mouse's defaults.")
                }
            }
            .disabled(model.readOnly)
        }
        .onChange(of: live) { reading.reported(live, steps: steps) }
        .onChange(of: model.writeError) { if model.writeError != nil { reading.clear() } }
        .onChange(of: exactValue) { settings?.refit() }
        .sheet(isPresented: Binding(get: { settings?.sheet == .presets }, set: { if !$0 { settings?.sheet = nil } })) {
            PresetsSheet(current: current, steps: steps) { setDPI($0) }
        }
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
