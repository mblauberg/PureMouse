import PureMouseAppSupport
import SwiftUI

/// What the thumb wheel's rows show at `path`, worked out from the state in effect and from which
/// keys the scope holds, so a row reads as it does in the wider scope until it sets its own value
/// (`InheritedValue`). Separate from the view so the rules can be tested.
struct ThumbWheelPresentation {
    let config: ConfigTree
    let path: [String]
    /// The state `path`'s keys apply on top of (`ThumbWheelRows.base`).
    let base: ThumbWheelState
    /// The wider scope's choice, for a mouse or an app; nil at the top level.
    let inherited: ThumbWheelChoice?
    let source: String
    let scope: ConfigScope

    /// The state in effect.
    var state: ThumbWheelState { config.thumbWheel(at: path, base: base) }
    /// The scope's own choice, `.inherit` while it sets none of the action's keys.
    var choice: ThumbWheelChoice { config.thumbWheelChoice(at: path) }
    /// What the wheel does in effect: the own choice, else the wider scope's.
    var effective: ThumbWheelChoice { choice == .inherit ? (inherited ?? .scroll) : choice }
    /// The Action row's value; nil at the top level, which has nothing wider.
    var action: InheritedValue<ThumbWheelChoice>? {
        inherited.map { InheritedValue(own: choice == .inherit ? nil : choice, inherited: $0, source: source) }
    }

    /// The scope holds `key` itself.
    func owns(_ key: String) -> Bool {
        scope.deviceKey != nil ? config.isOverridden(["thumbWheel", key], in: scope) : config.contains(path + [key])
    }

    /// Turn left and right rows exist while the action in effect is Custom, whoever set it.
    var showsDirections: Bool { effective == .custom && state.pair != nil }

    /// How a row for the config key `key` ("left", "right", "step", "reversed", "inverted") stands.
    func standing(of key: String, reset: @escaping () -> Void = {}) -> RowStanding {
        RowStanding(source: inherited == nil ? nil : source, isOwn: owns(key), reset: reset)
    }

    /// The Custom row for the way the key `key` turns: the scope's own action, else what the wider
    /// scope does for that key.
    func direction(_ key: String) -> InheritedValue<String> {
        let wider = base.pair.map { key == "left" ? $0.left : $0.right } ?? .named("none")
        let current = state.pair.map { key == "left" ? $0.left : $0.right } ?? .named("none")
        return InheritedValue(own: owns(key) ? current.label : nil, inherited: wider.label, source: source)
    }
}

/// The thumb wheel's rows, shared by the Scrolling pane (`["thumbWheel"]`, or a mouse's own, which
/// says "Set for this mouse." where it has its own value) and an app in the Apps pane (`["apps",
/// key, "thumbWheel"]`, "Set for this app."; `InheritedValue`). `.standard`: the Action
/// pop-up and, for Custom, an action per direction. `.advanced` (an Advanced… sheet or an app's
/// disclosure): the rows that apply to what the wheel does (`ThumbWheelAdvancedRow`), such as
/// swapping the directions and the turn distance. `.all`: both; in an app's sheet the advanced
/// rows sit under the "More thumb wheel options" disclosure.
struct ThumbWheelRows: View {
    enum Rows { case standard, advanced, all }

    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    let path: [String]
    var rows = Rows.all
    /// The state the keys at `path` apply on top of: none globally, the global one in an app.
    var base: ThumbWheelState = .initial
    /// In an app or on a mouse: the choice it falls back to, which the Action pop-up's "Same as …" entry keeps (`InheritedValue`).
    var inherited: ThumbWheelChoice?
    /// The scope `inherited` is from: Everywhere for an app, All Mice for a mouse.
    var source = InheritedScope.everywhere
    /// The mouse the rows edit (`path` is its `thumbWheel`), or `.global` for the top level and an app.
    var scope = ConfigScope.global
    /// In an app: its display name, which names the controls where several panes' rows read alike
    /// ("in Safari") and the editors that open from them.
    var appName: String?
    /// The mouse lacks a thumb wheel but a value is set: the Action row says so, and so do the
    /// advanced rows when they are all there is (`.advanced`).
    var availability = ControlAvailability.available

    /// The caption for the advanced rows: under `.all` the Action row above already carries it.
    private var advancedAvailability: ControlAvailability { rows == .advanced ? availability : .available }

    private var spokenSuffix: String { appName.map { " in \($0)" } ?? "" }

    @State private var presented: String?
    @State private var sheet: SheetRequest?
    /// In an app: "More thumb wheel options", the reverse and turn rows.
    @State private var showMore = false

    private var isMouse: Bool { scope.deviceKey != nil }

    private var presentation: ThumbWheelPresentation {
        ThumbWheelPresentation(config: model.config, path: path, base: base, inherited: inherited, source: source, scope: scope)
    }

    /// An edit in the scope the rows are for: a mouse's entry gets its name and loses it with its
    /// last value.
    private func edit(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) {
        if isMouse {
            model.update(debounce: debounce, in: model.scopeTarget, change)
        } else {
            model.update(debounce: debounce, change)  // All Mice and apps
        }
    }

    var body: some View {
        switch rows {
        case .standard: standardRows
        case .advanced: advancedRows
        case .all:
            standardRows
            if inherited == nil {
                advancedRows
            } else if !Self.advancedRows(model.config, path: path, base: base).isEmpty {
                // In an app (a sheet), the rest is a disclosure: no sheet opens from a sheet
                // (docs/ui-design.md, Disclosure).
                DisclosureLabel(title: "More thumb wheel options", isExpanded: $showMore)
                if showMore { advancedRows.disclosedRow() }
            }
        }
    }

    @ViewBuilder private var standardRows: some View {
        let config = model.config
        let choice = config.thumbWheelChoice(at: path)
        let state = config.thumbWheel(at: path, base: base)
        let set: (ThumbWheelChoice) -> Void = { new in edit { $0.chooseThumbWheel(new, at: path, base: base) } }
        let value = inherited.map { InheritedValue(own: choice == .inherit ? nil : choice, inherited: $0, source: source) }
        let note = value?.note { set(.inherit) }
        // What the wheel does in effect, which an inheriting row captions as the wider scope does.
        let effective = value?.effective ?? choice
        let caption = help(effective, reversed: state.reversed)
        LabeledContent {
            if let value {
                InheritedPicker(title: "Thumb wheel action\(spokenSuffix)", value: value,
                                options: ThumbWheelChoice.menu, label: \.label) { set($0 ?? .inherit) }
            } else {
                PopUpMenu(text: choice.label) {
                    Picker("Thumb wheel action\(spokenSuffix)", selection: Binding(get: { choice }, set: { set($0) })) {
                        ForEach(ThumbWheelChoice.menu) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("Thumb wheel action\(spokenSuffix)")
                .accessibilityValue(choice.label)
            }
        } label: {
            RowLabel("Action", help: caption, availability: availability, note: note,
                     spokenTitle: "Thumb wheel action\(spokenSuffix)")
        }
        .overridable(note, help: caption)
        // Custom adds rows.
        .onChange(of: choice) { settings?.refit() }
        .actionEditorSheet($sheet) { action, target in apply(action, to: target) }
        if presentation.showsDirections, let pair = state.pair {
            // Rows name the way the wheel turns; reversed, each shows the other key's action.
            direction("left", state.reversed ? pair.right : pair.left, reversed: state.reversed)
            direction("right", state.reversed ? pair.left : pair.right, reversed: state.reversed)
        }
    }

    /// What a mouse's thumb wheel keys apply on top of: All Mice's wheel. None at the top level, whose
    /// own keys are the base; an app passes the global one itself.
    static func base(_ config: ConfigTree, _ scope: ConfigScope) -> ThumbWheelState {
        scope.deviceKey == nil ? .initial : config.thumbWheel(at: ["thumbWheel"])
    }

    /// The rows that apply to what the wheel does at `path`.
    static func advancedRows(_ config: ConfigTree, path: [String], base: ThumbWheelState) -> [ThumbWheelAdvancedRow] {
        let inApp = path.first == "apps"
        return ThumbWheelAdvancedRow.rows(scrolls: config.thumbWheel(at: path, base: base).scrolls,
                                          someAppScrolls: config.someAppScrollsThumbWheel, inApp: inApp)
    }

    @ViewBuilder private var advancedRows: some View {
        let config = model.config
        let state = config.thumbWheel(at: path, base: base)
        ForEach(Self.advancedRows(config, path: path, base: base), id: \.self) { row in
            switch row {
            case .reverseScrolling: reverseScrolling(scrollsHere: state.scrolls)
            case .swapDirections: swapDirections(state)
            case .turnDistance: turnDistance(state)
            case .speed:
                ValueSlider(title: "Speed", spokenTitle: "Thumb wheel speed",
                            value: model.number(["smoothScroll", "horizontalSpeed"], default: 1, step: 0.05, in: model.scopeTarget),
                            range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier,
                            availability: advancedAvailability,
                            standing: model.standing(of: [["smoothScroll", "horizontalSpeed"]], in: model.scopeTarget))
                    // A scrolling speed: it applies while smooth scrolling is on.
                    .disabled(!config.smoothScrollEnabled(in: scope))
            }
        }
    }

    /// `inverted`: reverses the wheel's scrolling, here or in the apps where it scrolls.
    @ViewBuilder private func reverseScrolling(scrollsHere: Bool) -> some View {
        let inverted = model.config.bool(path + ["inverted"])
        let help = scrollsHere ? "Reverses this wheel." : "Reverses this wheel in apps where it scrolls."
        let effective = inverted ?? model.config.bool(["thumbWheel", "inverted"]) ?? false
        let standing = presentation.standing(of: "inverted") { edit { $0.setThumbWheelKey(nil, "inverted", at: path) } }
        let note = standing.note
        Toggle(isOn: Binding(get: { effective }, set: { on in edit { $0.setThumbWheelKey(on, "inverted", at: path) } })) {
            RowLabel("Reverse direction", help: help, mouseDefault: inherited == nil && inverted == nil,
                     availability: advancedAvailability, note: note, spokenTitle: "Reverse thumb wheel direction")
        }
        .overridable(note, help: help)
        .accessibilityLabel("Reverse thumb wheel direction")
        .accessibilityValue(standing.spoken(effective ? "On" : "Off"))
    }

    /// The turn distance: the wheel's own `step`, or the one the action in effect brings.
    private func turnDistance(_ state: ThumbWheelState) -> some View {
        let standing = presentation.standing(of: "step") { edit { $0.setThumbWheelKey(nil, "step", at: path) } }
        let note = standing.note
        let help = "How far to turn before the action repeats."
        return LabeledContent {
            HStack(spacing: 8) {
                Text("\(state.step)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Stepper("Turn distance\(spokenSuffix)",
                        value: Binding(get: { state.step },
                                       set: { new in edit(debounce: true) { $0.setThumbWheelKey(new, "step", at: path) } }),
                        in: 1...36)
                    .labelsHidden()
                    .accessibilityValue(standing.spoken("\(state.step)"))
            }
        } label: {
            RowLabel("Turn distance", help: help, availability: advancedAvailability, note: note,
                     spokenTitle: "Turn distance\(spokenSuffix)")
        }
        .overridable(note, help: help)
    }

    /// Swap directions: a switch, whose row says so when a mouse or an app sets it itself.
    @ViewBuilder private func swapDirections(_ state: ThumbWheelState) -> some View {
        let path = path
        let help = "Swaps what turning left and right does."
        let standing = presentation.standing(of: "reversed") { edit { $0.setThumbWheelReversed(nil, at: path) } }
        let note = standing.note
        Toggle(isOn: Binding(get: { state.reversed },
                             set: { on in edit { $0.setThumbWheelReversed(on, at: path) } })) {
            RowLabel("Swap directions", help: help, availability: advancedAvailability, note: note,
                     spokenTitle: "Swap thumb wheel directions\(spokenSuffix)")
        }
        .overridable(note, help: help)
        .accessibilityLabel("Swap thumb wheel directions\(spokenSuffix)")
        .accessibilityValue(standing.spoken(state.reversed ? "On" : "Off"))
    }

    private func help(_ choice: ThumbWheelChoice, reversed: Bool) -> String {
        switch choice {
        // Only reached for a wheel with nothing in effect to describe.
        case .inherit: ""
        case .scroll: ""  // the value says it
        case .preset("zoom"): reversed ? "Turn left to zoom in, right to zoom out." : "Turn left to zoom out, right to zoom in."
        case .preset("volume"): reversed ? "Turn left for louder, right for quieter." : "Turn left for quieter, right for louder."
        case .preset("tabs"):
            reversed ? "Turn left for the next tab, right for the previous." : "Turn left for the previous tab, right for the next."
        case .preset("spaces"): "Turn left or right to move between Spaces."
        case .preset: ""
        case .custom: "Choose what each direction does."
        }
    }

    /// The row for turning the wheel one way (`direction`), which sets the key that way's
    /// action is in: the other one while reversed. On a mouse or in an app it reads as the wider
    /// scope's action until set, and then says so.
    private func direction(_ direction: String, _ action: ButtonAction, reversed: Bool) -> some View {
        let title = direction == "left" ? "Turn left" : "Turn right"
        let key = ConfigTree.thumbWheelKey(turning: direction, reversed: reversed)
        let target = BindingTarget(button: "thumbWheel", direction: key, app: path.first == "apps" && path.count > 1 ? path[1] : nil,
                                   label: "turning the thumb wheel \(direction)", appName: appName)
        let spokenName = "Thumb wheel, \(title.lowercased())\(spokenSuffix)"
        let inherits = inherited != nil
        let value = presentation.direction(key)
        let note = inherits ? value.note { apply(.standard, to: target) } : nil
        return LabeledContent {
            ActionButton(action: inherits && value.isInherited ? .standard : action,
                         allowsDefault: false, allowsGesture: false,
                         isPresented: Binding(get: { presented == direction }, set: { presented = $0 ? direction : nil }),
                         choose: { entry in choose(entry, for: target, current: action) },
                         accessibilityName: spokenName,
                         sameAsEverywhere: inherits ? value.inherited : nil,
                         source: source)
        } label: {
            RowLabel(title, note: note, spokenTitle: spokenName)
        }
        .overridable(note, help: nil)
        .disclosedRow()
        .actionEditorPopover($sheet, for: target) { action, target in apply(action, to: target) }
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture: break
        case .shortcut:
            let initial = if case .keys(let spec) = current { spec } else { "" }
            DispatchQueue.main.async { sheet = SheetRequest(kind: .shortcut, target: target, initial: initial) }
        case .command:
            let initial = if case .run(let command) = current { command } else { "" }
            DispatchQueue.main.async { sheet = SheetRequest(kind: .command, target: target, initial: initial) }
        }
    }

    private func apply(_ action: ButtonAction, to target: BindingTarget) {
        guard let direction = target.direction else { return }
        // "Same as …" gives the key back; anything else sets it.
        edit { $0.setThumbWheel(direction, to: action == .standard ? nil : action, at: path) }
    }
}
