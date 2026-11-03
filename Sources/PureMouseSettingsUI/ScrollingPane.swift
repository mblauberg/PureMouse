import PureMouseAppSupport
import SwiftUI

/// Mouse › Scrolling: smooth scrolling, the main wheel and the thumb wheel's action, each row only
/// when the mouse can use it (`ScrollingLayout`); the rest in the Advanced… sheet.
struct ScrollingPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingAdvanced = false
    @State private var showingTryIt = false
    /// The section the device card sent the person to: outlined for a moment (`ArrivalOutline`).
    @State private var outline = ArrivalOutlineState()
    @State private var outlineTask: Task<Void, Never>?
    @AccessibilityFocusState private var focused: ScrollingSection?

    /// How long the outline stays before it fades.
    static let outlineDuration: Duration = .milliseconds(1500)

    static let restoreMessage = "Scrolling and thumb wheel settings return to PureMouse's defaults. App settings don't change."

    /// What Restore Defaults says for one mouse: its own values go, and it follows All Mice.
    static func restoreMessage(for mouse: String) -> String {
        "\(mouse) goes back to the All Mice scrolling and thumb wheel settings. App settings don't change."
    }

    var body: some View {
        let config = model.config
        let scope = model.scope, target = model.scopeTarget
        let layout = ScrollingLayout(config: config, devices: model.capabilityDevices(in: scope), scope: scope)
        let smooth = config.smoothScrollEnabled(in: scope)
        ScrollViewReader { proxy in
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
                                        standing: model.standing(of: [["smoothScroll", "speed"]], in: target))
                        }
                    }
                    // Dimmed, not hidden: the switch above brings them back.
                    .disabled(!smooth)
                    trySample
                }
            }

            // Built from its rows: a notched wheel has Reverse direction without Wheel mode or SmartShift.
            if !layout.mainWheelRows.isEmpty {
                Section {
                    Group {
                        if layout.shows(.reverseDirection) { reverseDirection(layout.availability(.reverseDirection)) }
                        if layout.shows(.wheelMode) { wheelMode(layout.availability(.wheelMode)) }
                        if layout.shows(.smartShift) { smartShift(layout.availability(.smartShift)) }
                    }
                    .arrivalBounds(.mainWheel)
                } header: {
                    sectionHeader(.mainWheel)
                }
            }

            if layout.showsThumbWheel {
                Section {
                    ThumbWheelRows(path: config.prefix(of: scope) + ["thumbWheel"], rows: .standard,
                                   base: ThumbWheelRows.base(config, scope),
                                   inherited: scope.deviceKey == nil ? nil : config.thumbWheelChoice(at: ["thumbWheel"]),
                                   source: InheritedScope.allMice, scope: scope,
                                   availability: layout.availability(.thumbWheelAction))
                        .arrivalBounds(.thumbWheel)
                } header: {
                    sectionHeader(.thumbWheel)
                }
            }

            Section {} footer: {
                PaneFooter(restoreDefaults: { model.update(in: target) { $0.restoreScrollingDefaults(in: scope) } },
                           restoreMessage: model.selectedMouse.map { Self.restoreMessage(for: $0.name) } ?? Self.restoreMessage,
                           advanced: layout.hasAdvanced ? { showingAdvanced = true } : nil)
            }
        }
        .overlayPreferenceValue(ArrivalBoundsKey.self) { bounds in
            ArrivalOutline(section: outline.section, bounds: bounds, reduceMotion: reduceMotion)
        }
        .disabled(model.readOnly)
        // A request from the device card: scroll to the section, outline it and move VoiceOver to its header.
        .onChange(of: settings?.arrival, initial: true) { _, section in
            guard let section else { return }
            arrive(at: section, proxy: proxy)
        }
        }
        .sheet(isPresented: $showingAdvanced) {
            ScrollingAdvancedSheet().environment(model)
        }
        .onChange(of: layout.hasAdvanced) { _, has in if !has { showingAdvanced = false } }
        // Try it adds or removes the sample's rows: the window refits (as Pointer's exact value does).
        .onChange(of: showingTryIt) { settings?.refit() }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["PUREMOUSE_DEV_TRY_IT"] != nil { showingTryIt = true }
            if DevHooks.sheet(on: "scrolling") == .advanced, layout.hasAdvanced { showingAdvanced = true }
            if let section = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_ARRIVAL"].flatMap(ScrollingSection.init(rawValue:)) {
                settings?.arrival = section
            }
        }
        #endif
    }

    private func sectionHeader(_ section: ScrollingSection) -> some View {
        Text(section.title)
            .id(section)
            .accessibilityFocused($focused, equals: section)
    }

    private func arrive(at section: ScrollingSection, proxy: ScrollViewProxy) {
        settings?.arrival = nil
        proxy.scrollTo(section, anchor: .top)
        let token = outline.begin(section)
        outlineTask?.cancel()
        // Let the pane lay out before VoiceOver is moved.
        DispatchQueue.main.async { focused = section }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PUREMOUSE_DEV_ARRIVAL_HOLD"] != nil { return }
        #endif
        outlineTask = Task { @MainActor in
            try? await Task.sleep(for: Self.outlineDuration)
            guard !Task.isCancelled else { return }
            outline.expire(token)
        }
    }

    private var target: ScopeTarget { model.scopeTarget }
    private var isMouse: Bool { model.scope.deviceKey != nil }

    /// A mouse's row is the same control as All Mice's; while the mouse has its own value it adds
    /// `InheritedValue`'s caption and the command that gives the value back.
    private func smoothScrolling(_ availability: ControlAvailability) -> some View {
        let scope = model.scope, target = model.scopeTarget
        let help = "Adds a glide to wheel scrolling. Apps can use their own settings."
        let value = InheritedValue(own: isMouse ? model.config.smoothScrollOwn(in: scope) : nil,
                                   inherited: model.config.smoothScrollEnabled, source: InheritedScope.allMice)
        let note = value.note { model.update(in: target) { $0.setSmoothScroll(nil, in: scope) } }
        let on = model.config.smoothScrollEnabled(in: scope)
        let standing = RowStanding(source: isMouse ? InheritedScope.allMice : nil, isOwn: !value.isInherited)
        return Toggle(isOn: Binding(get: { model.config.smoothScrollEnabled(in: scope) },
                                    set: { on in model.update(in: target) { $0.setSmoothScroll(on, in: scope) } })) {
            RowLabel("Smooth scrolling", help: help, availability: availability, note: note)
        }
        .overridable(note, help: help)
        .accessibilityLabel("Smooth scrolling")
        .accessibilityValue(standing.spoken(Self.spoken(on)))
    }

    /// What VoiceOver reads for a switch: the state, which an inheriting row follows with its source.
    static func spoken(_ on: Bool) -> String { on ? "On" : "Off" }

    /// Three presets; values no preset matches select none, and the caption says where they are.
    private func feel(_ availability: ControlAvailability) -> some View {
        let scope = model.scope, target = model.scopeTarget
        let config = model.config
        let selection = config.feelSelection(in: scope)
        let help = Feel.caption(for: selection)
        let value = InheritedValue(own: config.ownFeel(in: scope), inherited: config.globalFeel, source: InheritedScope.allMice)
        let note = value.note {
            model.update(in: target) {
                $0.removeOverrides([["smoothScroll", "acceleration"], ["smoothScroll", "smoothingMs"]], in: scope)
            }
        }
        let standing = RowStanding(source: isMouse ? InheritedScope.allMice : nil, isOwn: !value.isInherited)
        return LabeledContent {
            Picker("Feel", selection: Binding(get: { selection }, set: { feel in
                if let feel { model.update(in: target) { $0.apply(feel, in: scope) } }
            })) {
                ForEach(Feel.presets) { Text($0.label).tag($0 as Feel?) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityValue(standing.spoken(selection?.label ?? "No preset"))
        } label: {
            RowLabel("Feel", help: help, availability: availability, note: note, keepsHelp: selection == nil)
        }
        .overridable(note, help: selection == nil ? nil : help)
    }

    /// The three main wheel rows below always show a concrete value (`WheelDefaults`): the mouse's
    /// default while nothing is set, so none carries the "mouse's own setting" caption.
    private func reverseDirection(_ availability: ControlAvailability) -> some View {
        let path = WheelDefaults.reversedPath
        let scope = model.scope, target = model.scopeTarget
        let help = "Reverses this wheel."
        let standing = model.standing(of: [path], in: target)
        let note = standing.note
        let reversed = WheelDefaults.isReversed(model.config, in: scope)
        return Toggle(isOn: Binding(get: { reversed },
                                    set: { on in model.update(in: target) { WheelDefaults.chooseReversed(on, in: &$0, scope: scope) } })) {
            RowLabel("Reverse direction", help: help, availability: availability, note: note)
        }
        .overridable(note, help: help)
        .accessibilityLabel("Reverse main wheel direction")
        .accessibilityValue(standing.spoken(Self.spoken(reversed)))
    }

    private func wheelMode(_ availability: ControlAvailability) -> some View {
        let path = WheelDefaults.modePath
        let scope = model.scope, target = model.scopeTarget
        let live = model.liveDevice(in: scope)?.wheelMode
        let mode = WheelDefaults.mode(model.config, in: scope, live: live)
        let help = "Mode when the mouse connects."
        let standing = model.standing(of: [path], in: target)
        let note = standing.note
        return LabeledContent {
            Picker("Wheel mode", selection: Binding(get: { mode },
                                                    set: { new in model.update(in: target) { WheelDefaults.chooseMode(new, in: &$0, scope: scope) } })) {
                Text("Ratchet").tag(WheelDefaults.Mode.ratchet)
                Text("Free Spin").tag(WheelDefaults.Mode.freespin)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityValue(standing.spoken(mode == .freespin ? "Free Spin" : "Ratchet"))
        } label: {
            RowLabel("Wheel mode", help: help, availability: availability, note: note)
        }
        .overridable(note, help: help)
    }

    /// SmartShift: a switch (off writes 255, on writes 12 unless a wider scope already has it on);
    /// where it switches is in Advanced….
    private func smartShift(_ availability: ControlAvailability) -> some View {
        let path = WheelDefaults.smartShiftPath
        let scope = model.scope, target = model.scopeTarget
        let help = "Frees the wheel when you scroll fast."
        let standing = model.standing(of: [path], in: target)
        let note = standing.note
        let on = WheelDefaults.smartShiftIsOn(model.config, in: scope)
        return Toggle(isOn: Binding(get: { on },
                                    set: { on in model.update(in: target) { WheelDefaults.chooseSmartShift(on, in: &$0, scope: scope) } })) {
            RowLabel("SmartShift", help: help, availability: availability, note: note)
        }
        .overridable(note, help: help)
        .accessibilityLabel("SmartShift")
        .accessibilityValue(standing.spoken(Self.spoken(on)))
    }

    // MARK: Try it

    /// Lines in the sample; enough to scroll at any speed.
    static let sampleLineCount = 40
    /// The sample's height. A ScrollView has no intrinsic height, so the row must be given one;
    /// about six lines of body text.
    static let sampleHeight: CGFloat = 120

    static func sampleLine(_ number: Int) -> String { "Line \(number)" }

    /// A short scroll area under Feel and Speed, so a change is felt where it is made.
    @ViewBuilder private var trySample: some View {
        DisclosureLabel(title: "Try it", isExpanded: $showingTryIt)
        if showingTryIt {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(1...Self.sampleLineCount, id: \.self) { Text(Self.sampleLine($0)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            }
            .frame(height: Self.sampleHeight)
            .accessibilityLabel("Scrolling sample")
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
                                        standing: model.standing(of: [["smoothScroll", "acceleration"]], in: target))
                        }
                        if layout.shows(.glide) {
                            ValueSlider(title: "Glide", help: "Short glides stop sooner.",
                                        value: model.number(["smoothScroll", "smoothingMs"], default: 125, step: 25, in: target),
                                        range: 0...500, low: "Short", high: "Long", format: Format.milliseconds,
                                        availability: layout.availability(.glide),
                                        standing: model.standing(of: [["smoothScroll", "smoothingMs"]], in: target))
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
                                       base: ThumbWheelRows.base(config, scope),
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
        let scope = model.scope, target = model.scopeTarget
        let standing = model.standing(of: [path], in: target)
        let note = standing.note
        return Toggle(isOn: Binding(get: { model.config.resolvedBool(path, in: scope) ?? true },
                                    set: { on in model.update(in: target) { $0.set(on, at: path, in: scope) } })) {
            RowLabel("Hold Shift to scroll sideways", availability: availability, note: note)
        }
        .overridable(note, help: nil)
        .accessibilityLabel("Hold Shift to scroll sideways")
        .accessibilityValue(standing.spoken(ScrollingPane.spoken(model.config.resolvedBool(path, in: scope) ?? true)))
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
                           availability: availability, mouseDefault: threshold == nil,
                           standing: model.standing(of: [path], in: target))
    }
}

// MARK: Arriving from the device card

/// Where each section's rows are, in the form's coordinates (anchors, so they follow the scroll).
private struct ArrivalBoundsKey: PreferenceKey {
    static let defaultValue: [ScrollingSection: [Anchor<CGRect>]] = [:]

    static func reduce(value: inout [ScrollingSection: [Anchor<CGRect>]], nextValue: () -> [ScrollingSection: [Anchor<CGRect>]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

private extension View {
    /// Reports these rows' bounds as part of `section`.
    func arrivalBounds(_ section: ScrollingSection) -> some View {
        anchorPreference(key: ArrivalBoundsKey.self, value: .bounds) { [section: [$0]] }
    }
}

/// Which section is outlined after an arrival from the device card, and whose timeout may end it:
/// each arrival takes a token, and only the latest arrival's timeout clears the outline, so an
/// earlier one cannot cut a newer one short.
struct ArrivalOutlineState: Equatable {
    private(set) var section: ScrollingSection?
    private var latest = 0

    /// Outlines `section`; the token is the arrival's, for `expire`.
    mutating func begin(_ section: ScrollingSection) -> Int {
        latest += 1
        self.section = section
        return latest
    }

    /// Ends the outline, unless a later arrival has replaced the one `token` belongs to.
    mutating func expire(_ token: Int) {
        if token == latest { section = nil }
    }
}

/// The accent outline around the section the device card sent the person to. It fades after
/// `ScrollingPane.outlineDuration`; with Reduce Motion it appears and disappears without a fade.
private struct ArrivalOutline: View {
    let section: ScrollingSection?
    let bounds: [ScrollingSection: [Anchor<CGRect>]]
    let reduceMotion: Bool

    /// How far the outline stands off the rows, to the section's box.
    private static let margin: CGFloat = 10
    private static let corner = RectangleCornerRadii(topLeading: 12, bottomLeading: 12, bottomTrailing: 12, topTrailing: 12)

    var body: some View {
        GeometryReader { proxy in
            if let section, let anchors = bounds[section], let first = anchors.first {
                let rect = anchors.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                    .insetBy(dx: -Self.margin, dy: -Self.margin)
                UnevenRoundedRectangle(cornerRadii: Self.corner)
                    .strokeBorder(.tint, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: section)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
