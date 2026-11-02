import PureMouseAppSupport
import SwiftUI

/// The thumb wheel's rows, shared by the Scrolling pane (`["thumbWheel"]`) and an app in the Apps
/// pane (`["apps", key, "thumbWheel"]`, with "Same as Everywhere"). `.standard`: the Action
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
    /// In an app: the choice everywhere, which "Same as Everywhere" keeps (`InheritedValue`).
    var inherited: ThumbWheelChoice?
    /// In an app: its display name, which names the controls where several panes' rows read alike
    /// ("in Safari") and the editors that open from them.
    var appName: String?
    /// The mouse lacks a thumb wheel but a value is set: the Action row says so.
    var availability = ControlAvailability.available

    private var spokenSuffix: String { appName.map { " in \($0)" } ?? "" }

    @State private var presented: String?
    @State private var sheet: SheetRequest?
    /// In an app: "More thumb wheel options", the reverse and turn rows.
    @State private var showMore = false

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
        let set: (ThumbWheelChoice) -> Void = { new in model.update { $0.chooseThumbWheel(new, at: path, base: base) } }
        LabeledContent {
            if let inherited {
                InheritedPicker(title: "Thumb wheel action\(spokenSuffix)",
                                value: InheritedValue(own: choice == .inherit ? nil : choice, inherited: inherited,
                                                      source: InheritedScope.everywhere),
                                options: ThumbWheelChoice.menu, label: \.label) { set($0 ?? .inherit) }
            } else {
                Picker("Thumb wheel action\(spokenSuffix)", selection: Binding(get: { choice }, set: { set($0) })) {
                    ForEach(ThumbWheelChoice.menu) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        } label: {
            RowLabel("Action", help: help(choice, reversed: state.reversed), availability: availability)
        }
        // Custom adds rows.
        .onChange(of: choice) { settings?.refit() }
        .actionEditorSheet($sheet) { action, target in apply(action, to: target) }
        if choice == .custom, let pair = state.pair {
            // Rows name the way the wheel turns; reversed, each shows the other key's action.
            direction("left", state.reversed ? pair.right : pair.left, reversed: state.reversed)
            direction("right", state.reversed ? pair.left : pair.right, reversed: state.reversed)
        }
    }

    /// The rows that apply to what the wheel does at `path`.
    static func advancedRows(_ config: ConfigTree, path: [String], base: ThumbWheelState) -> [ThumbWheelAdvancedRow] {
        let inApp = path.first == "apps"
        return ThumbWheelAdvancedRow.rows(scrolls: config.thumbWheel(at: path, base: base).scrolls,
                                          someAppScrolls: config.someAppScrollsThumbWheel, inApp: inApp,
                                          inherits: config.thumbWheelChoice(at: path) == .inherit)
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
                            value: model.number(["smoothScroll", "horizontalSpeed"], default: 1, step: 0.05),
                            range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier)
                    // A scrolling speed: it applies while smooth scrolling is on.
                    .disabled(!config.smoothScrollEnabled)
            }
        }
    }

    /// `inverted`, global only: reverses the wheel's scrolling, here or in the apps where it scrolls.
    private func reverseScrolling(scrollsHere: Bool) -> some View {
        let inverted = model.config.bool(path + ["inverted"])
        return Toggle(isOn: model.toggle(path + ["inverted"], default: false)) {
            RowLabel("Reverse direction",
                     help: scrollsHere ? "Reverses this wheel." : "Reverses this wheel in apps where it scrolls.",
                     mouseDefault: inverted == nil)
        }
        .accessibilityLabel("Reverse thumb wheel direction")
    }

    private func turnDistance(_ state: ThumbWheelState) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text("\(state.step)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Stepper("Turn distance\(spokenSuffix)",
                        value: Binding(get: { state.step },
                                       set: { model.set($0, at: path + ["step"], debounce: true) }),
                        in: 1...36)
                    .labelsHidden()
                    .accessibilityValue("\(state.step)")
            }
        } label: {
            RowLabel("Turn distance", help: "How far to turn before the action repeats.")
        }
    }

    /// Swap directions: a switch globally; in an app a pop-up, since an app without the key
    /// follows the global setting.
    @ViewBuilder private func swapDirections(_ state: ThumbWheelState) -> some View {
        let path = path
        let caption = "Swaps what turning left and right does."
        if inherited == nil {
            Toggle(isOn: Binding(get: { state.reversed },
                                 set: { on in model.update { $0.setThumbWheelReversed(on, at: path) } })) {
                RowLabel("Swap directions", help: caption)
            }
            .accessibilityLabel("Swap thumb wheel directions\(spokenSuffix)")
        } else {
            let value = InheritedValue(own: model.config.thumbWheelReversed(at: path), inherited: base.reversed,
                                       source: InheritedScope.everywhere)
            LabeledContent {
                InheritedPicker(title: "Swap thumb wheel directions\(spokenSuffix)", value: value, options: [false, true],
                                label: { $0 ? "Swapped" : "Normal" }) { new in
                    model.update { $0.setThumbWheelReversed(new, at: path) }
                }
            } label: {
                RowLabel("Swap directions", help: value.caption ?? caption)
            }
        }
    }

    private func help(_ choice: ThumbWheelChoice, reversed: Bool) -> String {
        switch choice {
        // An app leaving it to everywhere: the `InheritedValue` caption.
        case .inherit: InheritedScope.sameAs(InheritedScope.everywhere)
        case .scroll: "Scrolls sideways."
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
    /// action is in: the other one while reversed.
    private func direction(_ direction: String, _ action: ButtonAction, reversed: Bool) -> some View {
        let title = direction == "left" ? "Turn left" : "Turn right"
        let key = ConfigTree.thumbWheelKey(turning: direction, reversed: reversed)
        let target = BindingTarget(button: "thumbWheel", direction: key, app: path.first == "apps" && path.count > 1 ? path[1] : nil,
                                   label: "turning the thumb wheel \(direction)", appName: appName)
        return LabeledContent(title) {
            ActionButton(action: action == .standard ? .named("none") : action,
                         allowsDefault: false, allowsGesture: false,
                         isPresented: Binding(get: { presented == direction }, set: { presented = $0 ? direction : nil }),
                         choose: { entry in choose(entry, for: target, current: action) },
                         accessibilityName: "Thumb wheel, \(title.lowercased())\(spokenSuffix)")
        }
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
        model.update { $0.setThumbWheel(direction, to: action, at: path) }
    }
}
