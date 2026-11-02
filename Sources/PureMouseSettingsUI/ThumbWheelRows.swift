import PureMouseAppSupport
import SwiftUI

/// The thumb wheel's rows, shared by the Scrolling pane (`["thumbWheel"]`) and an app in the Apps
/// pane (`["apps", key, "thumbWheel"]`, with "Same as Everywhere"). `.standard`: the Action
/// pop-up and, for Custom, an action per direction. `.advanced` (an Advanced… sheet or an app's
/// disclosure): the rows that apply to what the wheel does (`ThumbWheelAdvancedRow`), such as
/// swapping the directions and the turn distance. `.all`: both in one list, as the Apps pane
/// shows them until it has a place of its own for the advanced rows.
struct ThumbWheelRows: View {
    enum Rows { case standard, advanced, all }

    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    let path: [String]
    var rows = Rows.all
    /// The state the keys at `path` apply on top of: none globally, the global one in an app.
    var base: ThumbWheelState = .initial
    /// In an app: the global choice's label, which "Same as Everywhere" keeps.
    var inherited: String?
    /// Names the controls for VoiceOver where several panes' rows read alike ("in Safari").
    var spokenSuffix = ""
    /// The mouse lacks a thumb wheel but a value is set: the Action row says so.
    var availability = ControlAvailability.available

    @State private var presented: String?
    @State private var sheet: SheetRequest?

    var body: some View {
        switch rows {
        case .standard: standardRows
        case .advanced: advancedRows
        case .all:
            standardRows
            advancedRows
        }
    }

    @ViewBuilder private var standardRows: some View {
        let config = model.config
        let choice = config.thumbWheelChoice(at: path)
        let state = config.thumbWheel(at: path, base: base)
        LabeledContent {
            Picker("Thumb wheel action\(spokenSuffix)",
                   selection: Binding(get: { choice },
                                      set: { new in model.update { $0.chooseThumbWheel(new, at: path, base: base) } })) {
                if inherited != nil {
                    Text(ThumbWheelChoice.inherit.label).tag(ThumbWheelChoice.inherit)
                    Divider()
                }
                ForEach(ThumbWheelChoice.menu) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            RowLabel("Action", help: help(choice, reversed: state.reversed), availability: availability)
        }
        // Custom adds rows.
        .onChange(of: choice) { settings?.refit() }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .shortcut: ShortcutSheet(request: request) { apply(.keys($0), to: request.target) }
            case .command: CommandSheet(request: request) { apply(.run($0), to: request.target) }
            }
        }
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
            let own = model.config.thumbWheelReversed(at: path)
            LabeledContent {
                Picker("Swap thumb wheel directions\(spokenSuffix)",
                       selection: Binding(get: { own },
                                          set: { new in model.update { $0.setThumbWheelReversed(new, at: path) } })) {
                    Text("Same as Everywhere").tag(nil as Bool?)
                    Divider()
                    Text("Normal").tag(false as Bool?)
                    Text("Swapped").tag(true as Bool?)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                RowLabel("Swap directions",
                         help: own == nil ? "Everywhere: \(base.reversed ? "Swapped" : "Normal")." : caption)
            }
        }
    }

    private func help(_ choice: ThumbWheelChoice, reversed: Bool) -> String {
        switch choice {
        case .inherit: "Everywhere: \(inherited ?? ThumbWheelChoice.scroll.label)."
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
        let target = BindingTarget(button: "thumbWheel", direction: key,
                                   label: "turning the thumb wheel \(direction)")
        return LabeledContent(title) {
            ActionButton(action: action == .standard ? .named("none") : action,
                         allowsDefault: false, allowsGesture: false,
                         isPresented: Binding(get: { presented == direction }, set: { presented = $0 ? direction : nil }),
                         choose: { entry in choose(entry, for: target, current: action) },
                         accessibilityName: "Thumb wheel, \(title.lowercased())\(spokenSuffix)")
        }
        .disclosedRow()
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
