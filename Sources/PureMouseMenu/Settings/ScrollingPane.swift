import SwiftUI

struct ScrollingPane: View {
    @Environment(AppModel.self) private var model
    @State private var fineTune = false

    var body: some View {
        let config = model.config
        let smooth = config.smoothScrollEnabled
        let device = model.primaryDevice
        PaneForm {
            PaneBanners(needsAccessibility: true)
            Section {
                Toggle(isOn: Binding(get: { smooth }, set: { on in model.update { $0.smoothScrollEnabled = on } })) {
                    RowLabel("Smooth scrolling", help: "PureMouse animates both wheels. Off uses standard macOS scrolling.")
                }
                .accessibilityLabel("Smooth scrolling")
                Group {
                    LabeledContent {
                        Picker("Feel", selection: Binding(get: { config.feel }, set: { feel in model.update { $0.apply(feel) } })) {
                            ForEach(Feel.presets) { Text($0.label).tag($0) }
                            if config.feel == .custom { Text(Feel.custom.label).tag(Feel.custom) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        RowLabel("Feel", help: "How long a scroll glides, and how far fast flicks go.")
                    }
                    ValueSlider(title: "Speed", spokenTitle: "Scrolling speed", value: model.number(["smoothScroll", "speed"], default: 1, step: 0.05),
                                range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier)
                    LabeledContent {
                        if !fineTune {
                            Text("Acceleration, glide time, Shift for sideways")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        DisclosureLabel(title: "Fine-tune", isExpanded: $fineTune)
                    }
                    if fineTune {
                        ValueSlider(title: "Acceleration", help: "Extra distance when you spin the wheel fast.",
                                    value: model.number(["smoothScroll", "acceleration"], default: 1, step: 0.1),
                                    range: 0...3, low: "Off", high: "Strong",
                                    format: { $0 == 0 ? "Off" : Format.multiplier($0) })
                            .disclosedRow()
                        ValueSlider(title: "Glide", help: "0 scrolls instantly.",
                                    value: model.number(["smoothScroll", "smoothingMs"], default: 125, step: 25),
                                    range: 0...500, low: "Short", high: "Long", format: Format.milliseconds)
                            .disclosedRow()
                        Toggle("Shift + wheel scrolls sideways",
                               isOn: model.toggle(["smoothScroll", "shiftScrollsHorizontally"], default: true))
                            .disclosedRow()
                    }
                }
                // Dimmed, not hidden: the switch above brings them back.
                .disabled(!smooth)
            }

            if device?.hasSmartShift != false || config.contains(["scrollWheel"]) {
                Section("Main wheel") {
                    let inverted = config.bool(["scrollWheel", "inverted"])
                    Toggle(isOn: model.toggle(["scrollWheel", "inverted"], default: false)) {
                        RowLabel("Reverse direction", help: "Classic wheel direction while the trackpad stays natural.",
                                 mouseDefault: inverted == nil)
                    }
                    .accessibilityLabel("Reverse main wheel direction")
                    if device?.hasSmartShift != false {
                        wheelMode
                        smartShift
                    }
                }
            }

            if device?.hasThumbWheel != false || config.contains(["thumbWheel"]) {
                Section {
                    ThumbWheelRows(path: ["thumbWheel"])
                    Toggle(isOn: model.toggle(["thumbWheel", "inverted"], default: false)) {
                        RowLabel("Reverse direction", mouseDefault: config.bool(["thumbWheel", "inverted"]) == nil)
                    }
                    .accessibilityLabel("Reverse thumb wheel direction")
                    ValueSlider(title: "Speed", spokenTitle: "Thumb wheel speed", value: model.number(["smoothScroll", "horizontalSpeed"], default: 1, step: 0.05),
                                range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier)
                        // Scrolling speed: nothing to tune while the wheel performs actions.
                        .disabled(!smooth || !config.thumbWheel(at: ["thumbWheel"]).scrolls)
                } header: {
                    Text("Thumb wheel")
                } footer: {
                    restoreDefaults
                }
            } else {
                Section {} footer: { restoreDefaults }
            }
        }
        .disabled(model.readOnly)
    }

    private var restoreDefaults: some View {
        FooterButton("Restore Defaults") {
            model.update {
                // Smooth scrolling on, with every tuning at its default.
                $0.set([String: Any](), at: ["smoothScroll"])
                $0.set(nil, at: ["scrollWheel"])
                // Only the keys this pane shows; any others under thumbWheel stay.
                for key in ["inverted"] + ThumbWheelChoice.keys { $0.set(nil, at: ["thumbWheel", key]) }
            }
        }
    }

    private var wheelMode: some View {
        let mode = model.config.string(["scrollWheel", "mode"])
        return LabeledContent {
            Picker("Wheel mode", selection: Binding<String?>(get: { mode }, set: { model.set($0, at: ["scrollWheel", "mode"]) })) {
                Text("Ratchet").tag("ratchet" as String?)
                Text("Free Spin").tag("freespin" as String?)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } label: {
            RowLabel("Wheel mode", help: "Mode when the mouse connects. A button can still switch it.",
                     mouseDefault: mode == nil)
        }
    }

    /// SmartShift: a switch (off writes 255) and, while on, its threshold in an indented row.
    @ViewBuilder private var smartShift: some View {
        let threshold = model.config.int(["scrollWheel", "smartShiftThreshold"])
        let on = threshold.map { $0 < 255 } ?? true
        Toggle(isOn: Binding(get: { on }, set: { model.set($0 ? 12 : 255, at: ["scrollWheel", "smartShiftThreshold"]) })) {
            RowLabel("SmartShift", help: "Frees the wheel when you scroll fast.", mouseDefault: threshold == nil)
        }
        .accessibilityLabel("SmartShift")
        if on {
            LabeledContent("Threshold") {
                EndLabeledSlider(title: "SmartShift threshold",
                                 value: Binding(get: { Double(min(threshold ?? 12, 50)) },
                                                set: { model.set(Int($0.rounded()), at: ["scrollWheel", "smartShiftThreshold"], debounce: true) }),
                                 range: 1...50, low: "Sooner", high: "Later")
                    .frame(width: 200)
            }
            .disclosedRow()
        }
    }
}
