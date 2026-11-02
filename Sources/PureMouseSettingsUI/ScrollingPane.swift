import PureMouseAppSupport
import SwiftUI

/// Mouse › Scrolling: smooth scrolling, the main wheel and the thumb wheel's action, each row only
/// when the mouse can use it (`ScrollingLayout`); the rest in the Advanced… sheet.
struct ScrollingPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdvanced = false

    static let restoreMessage = "Scrolling and thumb wheel settings return to the mouse's defaults. App settings don't change."

    /// What Restore Defaults says for one mouse: its own values go, and it follows All Mice.
    static func restoreMessage(for mouse: String) -> String {
        "\(mouse) goes back to the All Mice scrolling and thumb wheel settings. App settings don't change."
    }

    var body: some View {
        let config = model.config
        let scope = model.scope, target = model.scopeTarget
        let layout = ScrollingLayout(config: config, devices: model.capabilityDevices(in: scope), scope: scope)
        let smooth = config.smoothScrollEnabled(in: scope)
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
                    if layout.shows(.smoothScrolling) { smoothScrolling(layout.availability(.smoothScrolling)) }
                    Group {
                        if layout.shows(.feel) { feel(layout.availability(.feel)) }
                        if layout.shows(.speed) {
                            ValueSlider(title: "Speed", spokenTitle: "Scrolling speed",
                                        value: model.number(["smoothScroll", "speed"], default: 1, step: 0.05, in: target),
                                        range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier,
                                        availability: layout.availability(.speed),
                                        inheritance: model.inheritance(of: [["smoothScroll", "speed"]], in: target))
                        }
                    }
                    // Dimmed, not hidden: the switch above brings them back.
                    .disabled(!smooth)
                }
            }

            // Built from its rows: a notched wheel has Reverse direction without Wheel mode or SmartShift.
            if !layout.mainWheelRows.isEmpty {
                Section("Main Wheel") {
                    if layout.shows(.reverseDirection) { reverseDirection(layout.availability(.reverseDirection)) }
                    if layout.shows(.wheelMode) { wheelMode(layout.availability(.wheelMode)) }
                    if layout.shows(.smartShift) { smartShift(layout.availability(.smartShift)) }
                }
            }

            if layout.showsThumbWheel {
                Section("Thumb Wheel") {
                    ThumbWheelRows(path: config.prefix(of: scope) + ["thumbWheel"], rows: .standard,
                                   inherited: scope.deviceKey == nil ? nil : config.thumbWheelChoice(at: ["thumbWheel"]),
                                   source: InheritedScope.allMice, scope: scope,
                                   availability: layout.availability(.thumbWheelAction))
                }
            }

            Section {} footer: {
                PaneFooter(restoreDefaults: { model.update(in: target) { $0.restoreScrollingDefaults(in: scope) } },
                           restoreMessage: model.selectedMouse.map { Self.restoreMessage(for: $0.name) } ?? Self.restoreMessage,
                           advanced: layout.hasAdvanced ? { showingAdvanced = true } : nil)
            }
        }
        .disabled(model.readOnly)
        .sheet(isPresented: $showingAdvanced) {
            ScrollingAdvancedSheet().environment(model)
        }
        .onChange(of: layout.hasAdvanced) { _, has in if !has { showingAdvanced = false } }
        #if DEBUG
        .onAppear { if DevHooks.sheet(on: "scrolling") == .advanced, layout.hasAdvanced { showingAdvanced = true } }
        #endif
    }

    private var target: ScopeTarget { model.scopeTarget }
    private var isMouse: Bool { model.scope.deviceKey != nil }

    private func smoothScrolling(_ availability: ControlAvailability) -> some View {
        let scope = model.scope
        let help = "Adds a glide to wheel scrolling. Apps can use their own settings."
        return Group {
            if isMouse {
                InheritedChoiceRow(title: "Smooth scrolling", help: help,
                                   value: InheritedValue(own: model.config.smoothScrollOwn(in: scope),
                                                         inherited: model.config.smoothScrollEnabled, source: InheritedScope.allMice),
                                   options: [false, true], text: { $0 ? "On" : "Off" }, availability: availability) { new in
                    model.update(in: target) { $0.setSmoothScroll(new, in: scope) }
                }
            } else {
                Toggle(isOn: Binding(get: { model.config.smoothScrollEnabled }, set: { on in model.update { $0.smoothScrollEnabled = on } })) {
                    RowLabel("Smooth scrolling", help: help, availability: availability)
                }
                .accessibilityLabel("Smooth scrolling")
            }
        }
    }

    /// Three presets; values no preset matches select none, and the caption says where they are.
    private func feel(_ availability: ControlAvailability) -> some View {
        let scope = model.scope
        let config = model.config
        let selection = config.feelSelection(in: scope)
        return Group {
            if isMouse {
                InheritedChoiceRow(title: "Feel", help: Feel.caption(for: selection),
                                   value: InheritedValue(own: config.ownFeel(in: scope), inherited: config.globalFeel,
                                                         source: InheritedScope.allMice),
                                   options: Feel.presets, text: { $0.label }, availability: availability) { new in
                    model.update(in: target) {
                        if let new { $0.apply(new, in: scope) } else {
                            $0.removeOverrides([["smoothScroll", "acceleration"], ["smoothScroll", "smoothingMs"]], in: scope)
                        }
                    }
                }
            } else {
                LabeledContent {
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
        }
    }

    private func reverseDirection(_ availability: ControlAvailability) -> some View {
        let path = ["scrollWheel", "inverted"]
        return Group {
            if isMouse {
                InheritedChoiceRow(title: "Reverse direction", help: "Reverses this wheel.",
                                   spokenTitle: "Reverse main wheel direction",
                                   value: model.inheritedBool(path, in: target, default: false),
                                   options: [false, true], text: { $0 ? "Reversed" : "Normal" },
                                   availability: availability) { new in
                    model.update(in: target) { $0.set(new, at: path, in: target.scope) }
                }
            } else {
                Toggle(isOn: model.toggle(path, default: false)) {
                    RowLabel("Reverse direction", help: "Reverses this wheel.",
                             mouseDefault: model.config.bool(path) == nil, availability: availability)
                }
                .accessibilityLabel("Reverse main wheel direction")
            }
        }
    }

    private func wheelMode(_ availability: ControlAvailability) -> some View {
        let mode = model.config.string(["scrollWheel", "mode"])
        return Group {
            if isMouse {
                // "" is a mode nobody set: the mouse keeps its own.
                InheritedChoiceRow(title: "Wheel mode", help: "Mode when the mouse connects.",
                                   value: model.inheritedString(["scrollWheel", "mode"], in: target, default: ""),
                                   options: ["ratchet", "freespin"],
                                   text: { $0 == "ratchet" ? "Ratchet" : $0 == "freespin" ? "Free Spin" : "Mouse's own" },
                                   availability: availability) { new in
                    model.update(in: target) { $0.set(new, at: ["scrollWheel", "mode"], in: target.scope) }
                }
            } else {
                LabeledContent {
                    Picker("Wheel mode", selection: Binding<String?>(get: { mode }, set: { model.set($0, at: ["scrollWheel", "mode"]) })) {
                        Text("Ratchet").tag("ratchet" as String?)
                        Text("Free Spin").tag("freespin" as String?)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    RowLabel("Wheel mode", help: "Mode when the mouse connects.",
                             mouseDefault: mode == nil, availability: availability)
                }
            }
        }
    }

    /// SmartShift: a switch (off writes 255); where it switches is in Advanced….
    private func smartShift(_ availability: ControlAvailability) -> some View {
        let path = ["scrollWheel", "smartShiftThreshold"]
        let scope = model.scope
        let threshold = model.config.int(path)
        let help = "Frees the wheel when you scroll fast."
        return Group {
            if isMouse {
                let own = model.config.isOverridden(path, in: scope) ? model.config.resolvedInt(path, in: scope).map { $0 < 255 } : nil
                InheritedChoiceRow(title: "SmartShift", help: help,
                                   value: InheritedValue(own: own, inherited: threshold.map { $0 < 255 } ?? true,
                                                         source: InheritedScope.allMice),
                                   options: [false, true], text: { $0 ? "On" : "Off" }, availability: availability) { new in
                    model.update(in: target) { $0.set(new.map { $0 ? 12 : 255 }, at: path, in: scope) }
                }
            } else {
                let on = threshold.map { $0 < 255 } ?? true
                Toggle(isOn: Binding(get: { on }, set: { model.set($0 ? 12 : 255, at: path) })) {
                    RowLabel("SmartShift", help: help, mouseDefault: threshold == nil, availability: availability)
                }
                .accessibilityLabel("SmartShift")
            }
        }
    }
}

/// Scrolling's Advanced… sheet: smooth scrolling's tuning, where SmartShift switches, and the
/// thumb wheel's rows for what it does. Each row shows only when it applies; the smooth
/// scrolling group dims while the switch is off.
private struct ScrollingAdvancedSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let scope = model.scope, target = model.scopeTarget
        let layout = ScrollingLayout(config: config, devices: model.capabilityDevices(in: scope), scope: scope)
        AdvancedSheet(title: "Advanced") {
            Group {
                if !layout.advancedSmoothScrollingRows.isEmpty {
                    Section("Smooth Scrolling") {
                        if layout.shows(.acceleration) {
                            ValueSlider(title: "Acceleration", help: "Extra distance when you spin the wheel fast.",
                                        value: model.number(["smoothScroll", "acceleration"], default: 1, step: 0.1, in: target),
                                        range: 0...3, low: "Off", high: "Strong", format: Format.strength,
                                        availability: layout.availability(.acceleration),
                                        inheritance: model.inheritance(of: [["smoothScroll", "acceleration"]], in: target))
                        }
                        if layout.shows(.glide) {
                            ValueSlider(title: "Glide", help: "0 scrolls instantly.",
                                        value: model.number(["smoothScroll", "smoothingMs"], default: 125, step: 25, in: target),
                                        range: 0...500, low: "Short", high: "Long", format: Format.milliseconds,
                                        availability: layout.availability(.glide),
                                        inheritance: model.inheritance(of: [["smoothScroll", "smoothingMs"]], in: target))
                        }
                        if layout.shows(.shiftScrollsSideways) {
                            shiftSideways(layout.availability(.shiftScrollsSideways))
                        }
                    }
                    .disabled(!config.smoothScrollEnabled(in: scope))
                }
                if layout.shows(.switchesAt) {
                    Section("Main Wheel") { switchesAt(layout.availability(.switchesAt)) }
                }
                if !layout.advancedThumbWheelRows.isEmpty {
                    Section("Thumb Wheel") {
                        ThumbWheelRows(path: config.prefix(of: scope) + ["thumbWheel"], rows: .advanced,
                                       inherited: scope.deviceKey == nil ? nil : config.thumbWheelChoice(at: ["thumbWheel"]),
                                       source: InheritedScope.allMice, scope: scope,
                                       availability: layout.availability(.thumbWheelAction))
                    }
                }
            }
            .disabled(model.readOnly)
        }
    }

    private func shiftSideways(_ availability: ControlAvailability) -> some View {
        let path = ["smoothScroll", "shiftScrollsHorizontally"]
        return Group {
            if model.scope.deviceKey != nil {
                InheritedChoiceRow(title: "Hold Shift to scroll sideways",
                                   value: model.inheritedBool(path, in: model.scopeTarget, default: true),
                                   options: [false, true], text: { $0 ? "On" : "Off" }, availability: availability) { new in
                    model.update(in: model.scopeTarget) { $0.set(new, at: path, in: model.scope) }
                }
            } else {
                Toggle(isOn: model.toggle(path, default: true)) {
                    RowLabel("Hold Shift to scroll sideways", availability: availability)
                }
                .accessibilityLabel("Hold Shift to scroll sideways")
            }
        }
    }

    /// The SmartShift threshold: how fast a scroll frees the wheel.
    private func switchesAt(_ availability: ControlAvailability) -> some View {
        let path = ["scrollWheel", "smartShiftThreshold"]
        let scope = model.scope, target = model.scopeTarget
        let threshold = model.config.resolvedInt(path, in: scope)
        return ValueSlider(title: "Switches at", help: "How fast you scroll before the wheel frees up.",
                           value: Binding(get: { Double(min(threshold ?? 12, 50)) },
                                          set: { model.set(Int($0.rounded()), at: path, in: target, debounce: true) }),
                           range: 1...50, low: "Slower", high: "Faster",
                           format: { String(Int($0.rounded())) },
                           availability: availability, mouseDefault: scope.deviceKey == nil && threshold == nil,
                           inheritance: model.inheritance(of: [path], in: target))
    }
}
