import PureMouseAppSupport
import PureMouseKit
import SwiftUI

struct PointerEditingState {
    var typed: Int?
    var reading = DPIReading()

    mutating func scopeChanged() {
        typed = nil
        reading.clear()
    }
}

struct PointerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.settings) private var settings
    @State private var editing = PointerEditingState()
    @State private var exactValue = false

    static let restoreMessage = "Pointer speed and presets return to PureMouse's defaults."

    /// What Restore Defaults says for one mouse: its own values go, and it follows All Mice.
    static func restoreMessage(for mouse: String) -> String {
        "\(mouse) goes back to the All Mice pointer speed and presets."
    }

    /// What the mouse has reported of the sensor's accepted values; empty before it has.
    private var reportedSteps: [Int] { model.primaryDevice(in: model.scope)?.dpiSteps ?? [] }

    /// The slider's steps: the mouse's, else the MX Master 3S's 200–8000 in steps of 50 until it reports.
    private var steps: [Int] {
        reportedSteps.isEmpty ? Array(stride(from: 200, through: 8000, by: 50)) : reportedSteps
    }

    private var configured: Int? { model.config.resolvedInt(["dpi"], in: model.scope) }
    private var live: Int? { model.liveDevice(in: model.scope)?.dpi }
    private var current: Int { editing.reading.current(live: live, configured: configured) }
    private var estimate: Bool { editing.reading.isEstimate(live: live, configured: configured) }

    var body: some View {
        let steps = steps
        let scope = model.scope, target = model.scopeTarget
        let presets = model.config.dpiPresets(in: scope)
        let layout = PointerLayout(config: model.config, devices: model.capabilityDevices(in: scope), scope: scope)
        let speed = model.standing(of: [["dpi"]], in: target)
        let presetsRow = model.standing(of: [["dpiPresets"]], in: target).note
        PaneForm {
            PaneBanners()
            Section {
                if layout.showsRows {
                    ValueSlider(title: PointerWords.title, spokenTitle: PointerWords.title,
                                help: PointerWords.help,
                                value: Binding(get: { Double(DPIReading.index(of: current, in: steps)) },
                                               set: { DPIReading.step(at: $0, in: steps).map { setDPI($0, debounce: true) } }),
                                range: 0...Double(max(steps.count - 1, 1)),
                                low: PointerWords.slow, high: PointerWords.fast,
                                format: { _ in editing.reading.readout(live: live, configured: configured) },
                                showsReadout: false, availability: layout.availability, mouseDefault: estimate, standing: speed)
                        // A sensor with a single setting has nothing to slide between.
                        .disabled(steps.count < 2)
                    LabeledContent {
                        if !exactValue {
                            Text(editing.reading.readout(live: live, configured: configured))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    } label: {
                        DisclosureLabel(title: "Exact value", isExpanded: $exactValue)
                    }
                    if exactValue {
                        LabeledContent {
                            HStack(spacing: 4) {
                                TextField("Pointer speed", value: Binding(get: { editing.typed ?? current }, set: { editing.typed = $0 }),
                                          format: .number.grouping(.automatic))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .labelsHidden()
                                    .onSubmit { commitTyped(steps) }
                                    .accessibilityLabel(PointerWords.exactLabel)
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
                        RowLabel("Presets", help: DPIPresets.summary(presets), availability: layout.availability,
                                 note: presetsRow)
                    }
                    .overridable(presetsRow, help: DPIPresets.summary(presets))
                } else {
                    // Nothing else on the pane applies, so say why it is bare.
                    LabeledContent {} label: {
                        RowLabel("Pointer speed", help: ControlAvailability.unsupportedCaption)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(PointerWords.footer)
                    Button {
                        openURL(URL(string: PointerWords.mouseSettingsURL)!)
                    } label: {
                        Text(PointerWords.openMouseSettings).padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.link)
                    PaneFooter(restoreDefaults: {
                        editing.scopeChanged()
                        model.update(in: target) { $0.restorePointerDefaults(in: scope) }
                    }, restoreMessage: model.selectedMouse.map { Self.restoreMessage(for: $0.name) } ?? Self.restoreMessage)
                }
            }
            .disabled(model.readOnly)
        }
        .onChange(of: scope) { editing.scopeChanged() }
        .onChange(of: live) { editing.reading.reported(live, steps: steps) }
        .onChange(of: model.writeError) { if model.writeError != nil { editing.reading.clear() } }
        .onChange(of: exactValue) { settings?.refit() }
        .sheet(isPresented: Binding(get: { settings?.sheet == .presets }, set: { if !$0 { settings?.sheet = nil } })) {
            PresetsSheet(current: current, steps: reportedSteps) { setDPI($0) }
        }
    }

    private func setDPI(_ dpi: Int, debounce: Bool = false) {
        editing.typed = nil
        guard !model.readOnly else { return }
        editing.reading.request(dpi)
        model.setDPI(dpi, debounce: debounce, in: model.scopeTarget)
    }

    private func commitTyped(_ steps: [Int]) {
        guard let typed = editing.typed else { return }
        let clamped = min(max(typed, Config.dpiRange.lowerBound), Config.dpiRange.upperBound)
        setDPI(DPIPresets.snap(clamped, to: steps))
    }
}
