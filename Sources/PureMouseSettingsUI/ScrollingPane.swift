import PureMouseAppSupport
import SwiftUI

/// Mouse › Scrolling: smooth scrolling, the main wheel and the thumb wheel's action, each row only
/// when the mouse can use it (`ScrollingLayout`); the rest in the Advanced… sheet.
struct ScrollingPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdvanced = false

    static let restoreMessage = "Scrolling and thumb wheel settings return to the mouse's defaults. App settings don't change."

    var body: some View {
        let config = model.config
        let layout = ScrollingLayout(config: config, devices: model.capabilityDevices)
        let smooth = config.smoothScrollEnabled
        PaneForm {
            PaneBanners(needsAccessibility: true)
            if layout.isEmpty {
                Section {
                    LabeledContent {} label: {
                        RowLabel("Smooth scrolling", help: ControlAvailability.unsupportedCaption)
                    }
                }
            }
            if !layout.smoothScrollingRows.isEmpty {
                Section {
                    if layout.shows(.smoothScrolling) {
                        Toggle(isOn: Binding(get: { smooth }, set: { on in model.update { $0.smoothScrollEnabled = on } })) {
                            RowLabel("Smooth scrolling", help: "Adds a glide to wheel scrolling. Apps can use their own settings.",
                                     availability: layout.availability(.smoothScrolling))
                        }
                        .accessibilityLabel("Smooth scrolling")
                    }
                    Group {
                        if layout.shows(.feel) { feel(config, layout.availability(.feel)) }
                        if layout.shows(.speed) {
                            ValueSlider(title: "Speed", spokenTitle: "Scrolling speed",
                                        value: model.number(["smoothScroll", "speed"], default: 1, step: 0.05),
                                        range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier,
                                        availability: layout.availability(.speed))
                        }
                    }
                    // Dimmed, not hidden: the switch above brings them back.
                    .disabled(!smooth)
                }
            }

            // Built from its rows: a notched wheel has Reverse direction without Wheel mode or SmartShift.
            if !layout.mainWheelRows.isEmpty {
                Section("Main Wheel") {
                    if layout.shows(.reverseDirection) {
                        Toggle(isOn: model.toggle(["scrollWheel", "inverted"], default: false)) {
                            RowLabel("Reverse direction", help: "Reverses this wheel.",
                                     mouseDefault: config.bool(["scrollWheel", "inverted"]) == nil,
                                     availability: layout.availability(.reverseDirection))
                        }
                        .accessibilityLabel("Reverse main wheel direction")
                    }
                    if layout.shows(.wheelMode) { wheelMode(layout.availability(.wheelMode)) }
                    if layout.shows(.smartShift) { smartShift(layout.availability(.smartShift)) }
                }
            }

            if layout.showsThumbWheel {
                Section("Thumb Wheel") {
                    ThumbWheelRows(path: ["thumbWheel"], rows: .standard, availability: layout.availability(.thumbWheelAction))
                }
            }

            Section {} footer: {
                PaneFooter(restoreDefaults: { model.update { $0.restoreScrollingDefaults() } },
                           restoreMessage: Self.restoreMessage,
                           advanced: layout.hasAdvanced ? { showingAdvanced = true } : nil)
            }
        }
        .disabled(model.readOnly)
        .sheet(isPresented: $showingAdvanced) {
            ScrollingAdvancedSheet().environment(model)
        }
        .onChange(of: layout.hasAdvanced) { _, has in if !has { showingAdvanced = false } }
        #if DEBUG
        .onAppear { if DevHooks.sheet == .advanced, layout.hasAdvanced { showingAdvanced = true } }
        #endif
    }

    /// Three presets; values no preset matches select none, and the caption says where they are.
    private func feel(_ config: ConfigTree, _ availability: ControlAvailability) -> some View {
        let selection = config.feelSelection
        return LabeledContent {
            Picker("Feel", selection: Binding(get: { selection }, set: { feel in
                if let feel { model.update { $0.apply(feel) } }
            })) {
                ForEach(Feel.presets) { Text($0.label).tag($0 as Feel?) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } label: {
            RowLabel("Feel", help: Feel.caption(for: selection), availability: availability)
        }
    }

    private func wheelMode(_ availability: ControlAvailability) -> some View {
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
                     mouseDefault: mode == nil, availability: availability)
        }
    }

    /// SmartShift: a switch (off writes 255); where it switches is in Advanced….
    private func smartShift(_ availability: ControlAvailability) -> some View {
        let threshold = model.config.int(["scrollWheel", "smartShiftThreshold"])
        let on = threshold.map { $0 < 255 } ?? true
        return Toggle(isOn: Binding(get: { on }, set: { model.set($0 ? 12 : 255, at: ["scrollWheel", "smartShiftThreshold"]) })) {
            RowLabel("SmartShift", help: "Frees the wheel when you scroll fast.", mouseDefault: threshold == nil,
                     availability: availability)
        }
        .accessibilityLabel("SmartShift")
    }
}

/// Scrolling's Advanced… sheet: smooth scrolling's tuning, where SmartShift switches, and the
/// thumb wheel's rows for what it does. Each row shows only when it applies; the smooth
/// scrolling group dims while the switch is off.
private struct ScrollingAdvancedSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let layout = ScrollingLayout(config: config, devices: model.capabilityDevices)
        AdvancedSheet(title: "Advanced") {
            Group {
                if !layout.advancedSmoothScrollingRows.isEmpty {
                    Section("Smooth Scrolling") {
                        if layout.shows(.acceleration) {
                            ValueSlider(title: "Acceleration", help: "Extra distance when you spin the wheel fast.",
                                        value: model.number(["smoothScroll", "acceleration"], default: 1, step: 0.1),
                                        range: 0...3, low: "Off", high: "Strong", format: Format.strength)
                        }
                        if layout.shows(.glide) {
                            ValueSlider(title: "Glide", help: "0 scrolls instantly.",
                                        value: model.number(["smoothScroll", "smoothingMs"], default: 125, step: 25),
                                        range: 0...500, low: "Short", high: "Long", format: Format.milliseconds)
                        }
                        if layout.shows(.shiftScrollsSideways) {
                            Toggle("Hold Shift to scroll sideways",
                                   isOn: model.toggle(["smoothScroll", "shiftScrollsHorizontally"], default: true))
                        }
                    }
                    .disabled(!config.smoothScrollEnabled)
                }
                if layout.shows(.switchesAt) {
                    Section("Main Wheel") { switchesAt }
                }
                if !layout.advancedThumbWheelRows.isEmpty {
                    Section("Thumb Wheel") {
                        ThumbWheelRows(path: ["thumbWheel"], rows: .advanced)
                    }
                }
            }
            .disabled(model.readOnly)
        }
    }

    /// The SmartShift threshold: how fast a scroll frees the wheel.
    private var switchesAt: some View {
        let threshold = model.config.int(["scrollWheel", "smartShiftThreshold"])
        return LabeledContent {
            EndLabeledSlider(title: "Switches at",
                             value: Binding(get: { Double(min(threshold ?? 12, 50)) },
                                            set: { model.set(Int($0.rounded()), at: ["scrollWheel", "smartShiftThreshold"], debounce: true) }),
                             range: 1...50, low: "Slower", high: "Faster")
                .frame(width: 200)
        } label: {
            RowLabel("Switches at", help: "How fast you scroll before the wheel frees up.", mouseDefault: threshold == nil)
        }
    }
}
