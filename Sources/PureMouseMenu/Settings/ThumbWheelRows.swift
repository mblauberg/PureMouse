import SwiftUI

/// What turning the thumb wheel does: a pop-up of choices and, for Custom, an action per
/// direction, plus the turn per action. Shared by the Scrolling pane (`["thumbWheel"]`) and an
/// app in the Apps pane (`["apps", key, "thumbWheel"]`, with "Same as Everywhere").
struct ThumbWheelRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.app) private var app
    let path: [String]
    /// The state the keys at `path` apply on top of: none globally, the global one in an app.
    var base: ThumbWheelState = .initial
    /// In an app: the global choice's label, which "Same as Everywhere" keeps.
    var inherited: String?
    /// Names the controls for VoiceOver where several panes' rows read alike ("in Safari").
    var spokenSuffix = ""

    @State private var presented: String?
    @State private var sheet: SheetRequest?

    var body: some View {
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
            RowLabel("Action", help: help(choice))
        }
        // Custom and the turn per action add rows.
        .onChange(of: choice) { app?.refitSettings() }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .shortcut: ShortcutSheet(request: request) { apply(.keys($0), to: request.target) }
            case .command: CommandSheet(request: request) { apply(.run($0), to: request.target) }
            }
        }
        if choice == .custom, let pair = state.pair {
            direction("left", pair.left)
            direction("right", pair.right)
        }
        if !state.scrolls, choice != .inherit {
            LabeledContent {
                HStack(spacing: 8) {
                    Text("\(state.step)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Stepper("Turn per action\(spokenSuffix)",
                            value: Binding(get: { state.step },
                                           set: { model.set($0, at: path + ["step"], debounce: true) }),
                            in: 1...36)
                        .labelsHidden()
                        .accessibilityValue("\(state.step) steps")
                }
            } label: {
                RowLabel("Turn per action", help: "In wheel steps; a full turn is about 18. Fewer acts sooner.")
            }
        }
    }

    private func help(_ choice: ThumbWheelChoice) -> String {
        switch choice {
        case .inherit: "Everywhere: \(inherited ?? ThumbWheelChoice.scroll.label)."
        case .scroll: "Scrolls sideways, as without PureMouse."
        case .preset("zoom"): "Turn left to zoom out, right to zoom in."
        case .preset("volume"): "Turn left for quieter, right for louder."
        case .preset("tabs"): "Turn left for the previous tab, right for the next."
        case .preset("spaces"): "Turn left or right to move between Spaces."
        case .preset: ""
        case .custom: "Choose what each direction does."
        }
    }

    private func direction(_ direction: String, _ action: ButtonAction) -> some View {
        let title = direction == "left" ? "Turn left" : "Turn right"
        let target = BindingTarget(button: "thumbWheel", direction: direction,
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
