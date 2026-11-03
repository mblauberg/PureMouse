import PureMouseAppSupport
import PureMouseKit
import SwiftUI

struct ButtonsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    /// The control whose picker is open: a button key, or "button.direction".
    @State private var presented: String?
    @State private var highlighted: String?
    @State private var sheet: SheetRequest?
    /// Gesture buttons whose directions show; collapsed until opened or chosen.
    @State private var expanded: Set<String> = []
    @State private var showOthers = false
    @State private var showingAdvanced = false

    static let restoreMessage = "Buttons and gestures return to the mouse's defaults. App settings don't change."

    /// What Restore Defaults says for one mouse: its own values go, and it follows All Mice.
    static func restoreMessage(for mouse: String) -> String {
        "\(mouse) goes back to the All Mice buttons and gestures. App settings don't change."
    }

    private var scope: ConfigScope { model.scope }
    private var isMouse: Bool { scope.deviceKey != nil }

    var body: some View {
        let usesGestures = model.config.usesGestures
        let scope = model.scope, target = model.scopeTarget
        let plan = cardPlan
        ScrollViewReader { proxy in
        PaneForm {
            PaneBanners(needsAccessibility: true)
            if let plan, let mouse = cardMouse {
                Section {
                    DeviceCard(plan: plan, name: mouse.name, actions: cardActions, selected: card?.button,
                               activate: { settings?.activate($0) })
                }
            }
            Section {
                ForEach(namedRows, id: \.self) { key in row(key) }
                if !otherRows.isEmpty {
                    DisclosureLabel(title: "Other controls", isExpanded: $showOthers)
                    if showOthers {
                        ForEach(otherRows, id: \.self) { key in row(key, indented: true) }
                    }
                }
            } header: {
                // Find by Pressing… and its Cancel are in the Mouse tab's header strip, which
                // announces the outcome; the strip has no room beside its segments for the words.
                if model.captureListening {
                    Text("Press a button on your mouse")
                } else if let outcome = model.captureOutcome {
                    Text(outcome.message)
                }
            } footer: {
                // Advanced… holds the gesture distance and repeat, so only while some button
                // (globally or in an app) is Hold and Move.
                PaneFooter(restoreDefaults: { model.update(in: target) { $0.restoreButtonDefaults(in: scope) } },
                           restoreMessage: model.selectedMouse.map { Self.restoreMessage(for: $0.name) } ?? Self.restoreMessage,
                           advanced: usesGestures ? { showingAdvanced = true } : nil)
            }
            .disabled(model.readOnly)
        }
        // Choosing a part of the drawing brings its row into view.
        .onChange(of: card?.button) { _, button in
            guard let button else { return }
            proxy.scrollTo(button.rawValue)
        }
        }
        .sheet(isPresented: $showingAdvanced) {
            ButtonsAdvancedSheet().environment(model)
        }
        // The sheet's rows are about Hold and Move: with none left, it has nothing to show.
        .onChange(of: usesGestures) { _, uses in if !uses { showingAdvanced = false } }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .shortcut: ShortcutSheet(request: request) { apply(.keys($0), to: request.target) }
            case .command: CommandSheet(request: request) { apply(.run($0), to: request.target) }
            }
        }
        #if DEBUG
        .onAppear {
            if DevHooks.sheet(on: "buttons") == .advanced, usesGestures { showingAdvanced = true }
            let environment = ProcessInfo.processInfo.environment
            if environment["PUREMOUSE_DEV_OTHERS"] != nil { showOthers = true }
            // After the card's first `follow`, which clears a selection made for another mouse.
            if let key = environment["PUREMOUSE_DEV_BUTTON"].flatMap(NamedButton.init(rawValue:)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { card?.select(key) }
            }
            if let key = environment["PUREMOUSE_DEV_FOUND"] { highlighted = key }
            if let key = environment["PUREMOUSE_DEV_PICKER"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presented = key }
            }
            if let key = environment["PUREMOUSE_DEV_SHORTCUT"] {
                sheet = SheetRequest(kind: .shortcut, target: BindingTarget(button: key), initial: "cmd+w")
            }
        }
        #endif
        // The prompt above the rows comes and goes.
        .onChange(of: model.captureListening) { settings?.refit() }
        .onChange(of: model.captureOutcome) { settings?.refit() }
        .onChange(of: expanded) { settings?.refit() }
        .onChange(of: showOthers) { settings?.refit() }
        // The card comes and goes with the mouse chosen, which changes the pane's height.
        .onChange(of: plan != nil) { settings?.refit() }
        .onChange(of: cardMouse?.key, initial: true) { _, key in card?.follow(mouse: key) }
        .onChange(of: model.capturedButton) { _, key in
            guard let key else { return }
            model.capturedButton = nil
            if !namedRows.contains(key) { showOthers = true }
            highlighted = key
            card?.select(NamedButton(rawValue: key))
            presented = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if highlighted == key { highlighted = nil } }
        }
    }

    // MARK: Rows

    /// Controls the mice in the scope have (nil when none has reported any).
    private var deviceCIDs: Set<UInt16>? {
        let cids = model.reportedControlIDs(in: scope)
        return cids.isEmpty ? nil : Set(cids)
    }

    private var configKeys: [String] { model.boundButtonKeys(in: scope) }

    private var namedRows: [String] {
        ButtonRows.named(deviceCIDs: deviceCIDs, configKeys: configKeys).map(\.rawValue)
    }

    private var card: CardSelection? { settings?.card }

    /// The mouse the device card draws: the chosen one, else the only one known.
    private var cardMouse: KnownMouse? {
        DeviceCardPlan.mouse(selected: model.selectedMouse, known: model.knownMice, offersChoice: model.showsMouseMenu)
    }

    /// The card's parts, from what the mouse has and what Scrolling shows for it; nil for a mouse
    /// with no drawing.
    private var cardPlan: DeviceCardPlan? {
        guard let mouse = cardMouse, let art = DeviceArt.model(forKey: mouse.key) else { return nil }
        let layout = ScrollingLayout(config: model.config, devices: model.capabilityDevices(in: scope), scope: scope)
        return DeviceCardPlan(model: art, listed: Set(namedRows.compactMap { NamedButton(rawValue: $0) }),
                              mainWheelSettings: !layout.mainWheelRows.isEmpty, thumbWheelSettings: layout.showsThumbWheel)
    }

    /// Each listed button's action, as its row shows it and as VoiceOver says it.
    private var cardActions: [NamedButton: DeviceCardPlan.ActionText] {
        var actions: [NamedButton: DeviceCardPlan.ActionText] = [:]
        for key in namedRows {
            guard let button = NamedButton(rawValue: key) else { continue }
            let action = shownAction(key)
            actions[button] = .init(shown: ActionButton.shortened(action.label), spoken: action.spokenLabel)
        }
        return actions
    }

    /// The action a row shows for a button: the mouse's own, else what it inherits.
    private func shownAction(_ key: String) -> ButtonAction {
        guard isMouse else { return model.config.binding(key) }
        let state = model.config.scopedButton(key, in: scope)
        return state.own == .standard ? state.everywhere : state.own
    }

    private var otherRows: [String] {
        ButtonRows.others(deviceCIDs: model.reportedControlIDs(in: scope), configKeys: configKeys)
    }

    /// Where an "Other controls" entry lives, for its help line.
    private func caption(_ key: String) -> String? {
        guard NamedButton(rawValue: key) == nil, let cid = NamedButton.cid(forKey: key) else { return nil }
        // No devices: none connected, or paused (the daemon then reports none).
        let devices = model.devices(in: scope)
        guard !devices.isEmpty else { return nil }
        let owners = devices.filter { $0.controls.contains { $0.cid == cid } }.map(\.name)
        return owners.isEmpty ? ControlAvailability.unsupportedCaption : owners.joined(separator: ", ")
    }

    @ViewBuilder
    private func row(_ key: String, indented: Bool = false) -> some View {
        if isMouse { mouseRow(key, indented: indented) } else { globalRow(key, indented: indented) }
    }

    /// A button on a mouse: the binding that applies, shown as in All Mice; with its own, the row
    /// says "Set for this mouse." (`InheritedValue`, as on an app's page).
    @ViewBuilder
    private func mouseRow(_ key: String, indented: Bool) -> some View {
        let state = model.config.scopedButton(key, in: scope)
        let everywhere = state.everywhere.label
        let spokenEverywhere = state.everywhere.spokenLabel
        let target = BindingTarget(button: key)
        let mark = RowMark.of(key, selected: card?.button, found: highlighted)
        let note = ActionButton.inherited(state.own, everywhere: everywhere, source: InheritedScope.allMice)
            .note { apply(.standard, to: target) }
        if state.directions.isEmpty {
            let help = caption(key)
            LabeledContent {
                actionButton(state.own, target: target, sameAsEverywhere: everywhere, spokenEverywhere: spokenEverywhere)
            } label: {
                RowLabel(NamedButton.title(forKey: key), help: help, note: note)
                    .foregroundStyle(titleStyle(mark))
            }
            .overridable(note, help: help)
            .padding(.leading, indented ? 16 : 0)
            .rowMark(mark)
            .id(key)
        } else {
            let isExpanded = Binding(get: { expanded.contains(key) },
                                     set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
            let help = model.config.gestureSummary(key, in: scope)
            LabeledContent {
                actionButton(state.own, target: target, sameAsEverywhere: everywhere, spokenEverywhere: spokenEverywhere)
            } label: {
                DisclosureLabel(title: NamedButton.title(forKey: key), help: help, note: note,
                                spokenTitle: "\(NamedButton.title(forKey: key)) directions", isExpanded: isExpanded)
                    .foregroundStyle(titleStyle(mark))
            }
            .overridable(note, help: help)
            .padding(.leading, indented ? 16 : 0)
            .rowMark(mark)
            .id(key)
            if isExpanded.wrappedValue {
                Text("Hold the button and move the mouse. Release without moving to click.")
                    .foregroundStyle(.secondary)
                    .padding(.leading, indented ? 38 : 22)
                ForEach(state.directions, id: \.name) { direction in
                    // A direction the mouse leaves out follows the All Mice gesture's, if it has one,
                    // else does nothing; one it sets itself is marked either way.
                    let target = BindingTarget(button: key, direction: direction.name)
                    let note = ActionButton.inherited(direction, source: InheritedScope.allMice).note { apply(.standard, to: target) }
                    LabeledContent {
                        actionButton(direction.own, target: target, sameAsEverywhere: direction.inherited.label,
                                     spokenEverywhere: direction.inherited.spokenLabel)
                    } label: {
                        RowLabel(Gesture.label(direction.name), note: note, spokenTitle: target.title)
                    }
                    .overridable(note, help: nil)
                    .padding(.leading, indented ? 38 : 22)
                }
            }
        }
    }

    @ViewBuilder
    private func globalRow(_ key: String, indented: Bool) -> some View {
        let action = model.config.binding(key)
        let mark = RowMark.of(key, selected: card?.button, found: highlighted)
        if action == .gesture {
            let isExpanded = Binding(get: { expanded.contains(key) },
                                     set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
            LabeledContent {
                actionButton(action, target: BindingTarget(button: key))
            } label: {
                DisclosureLabel(title: NamedButton.title(forKey: key), help: model.config.gestureSummary(key),
                                spokenTitle: "\(NamedButton.title(forKey: key)) directions", isExpanded: isExpanded)
                    .foregroundStyle(titleStyle(mark))
            }
            .padding(.leading, indented ? 16 : 0)
            .rowMark(mark)
            .id(key)
            if isExpanded.wrappedValue {
                Text("Hold the button and move the mouse. Release without moving to click.")
                    .foregroundStyle(.secondary)
                    .padding(.leading, indented ? 38 : 22)
                ForEach(Gesture.directions, id: \.self) { direction in
                    LabeledContent(Gesture.label(direction)) {
                        actionButton(model.config.gestureBinding(key, direction),
                                     target: BindingTarget(button: key, direction: direction))
                    }
                    .padding(.leading, indented ? 38 : 22)
                }
            }
        } else {
            LabeledContent {
                actionButton(action, target: BindingTarget(button: key))
            } label: {
                RowLabel(NamedButton.title(forKey: key), help: caption(key))
                    .foregroundStyle(titleStyle(mark))
            }
            .padding(.leading, indented ? 16 : 0)
            .rowMark(mark)
            .id(key)
        }
    }

    /// A marked row's title is in the accent colour (`RowMark`).
    private func titleStyle(_ mark: RowMark) -> AnyShapeStyle {
        mark.tintsTitle ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget, sameAsEverywhere: String? = nil,
                              spokenEverywhere: String? = nil) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        let inherits = sameAsEverywhere != nil
        return ActionButton(
            action: isDirection && action == .standard && !inherits ? .named("none") : action,
            // On a mouse, Mouse Default is its own value ("default") beside "Same as All Mice".
            allowsDefault: !isDirection && PickerEntry.offersMouseDefault(for: target.button, inMouseOrApp: isMouse, current: action),
            allowsGesture: !isDirection,
            isPresented: Binding(get: { presented == id }, set: { open in
                presented = open ? id : nil
                if open, let button = NamedButton(rawValue: target.button) { card?.select(button) }
            }),
            choose: { entry in choose(entry, for: target, current: action) },
            accessibilityName: target.title + (inherits && model.selectedMouse != nil ? ", \(model.selectedMouse?.name ?? "")" : ""),
            sameAsEverywhere: sameAsEverywhere,
            spokenEverywhere: spokenEverywhere,
            source: InheritedScope.allMice,
            scope: scope)
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        highlighted = nil
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture:
            apply(.gesture, to: target)
            expanded.insert(target.button)
        case .shortcut:
            let initial = if case .keys(let spec) = current { spec } else { "" }
            // Let the popover close before the sheet opens.
            DispatchQueue.main.async { sheet = SheetRequest(kind: .shortcut, target: target, initial: initial) }
        case .command:
            let initial = if case .run(let command) = current { command } else { "" }
            DispatchQueue.main.async { sheet = SheetRequest(kind: .command, target: target, initial: initial) }
        }
    }

    private func apply(_ action: ButtonAction, to target: BindingTarget) {
        let scope = scope
        model.update(in: model.scopeTarget) {
            if let direction = target.direction {
                $0.bind(target.button, direction: direction, to: action, in: scope)
            } else {
                $0.bind(target.button, to: action, in: scope)
            }
        }
    }
}

/// Buttons' Advanced… sheet: how Hold and Move feels.
private struct ButtonsAdvancedSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = model.scopeTarget
        AdvancedSheet(title: "Advanced") {
            Section("Hold and Move") {
                ValueSlider(title: "Distance", help: "How far to move while holding before a direction fires.",
                            value: model.number(["gesture", "distanceMm"], default: 4, step: 0.5, in: target),
                            range: 2...12, low: "Short", high: "Long", format: Format.millimetres,
                            standing: model.standing(of: [["gesture", "distanceMm"]], in: target))
                ValueSlider(title: "Repeat", help: "Keep moving to repeat, such as across several Spaces.",
                            value: model.number(["gesture", "repeatIntervalMs"], default: 400, step: 50, in: target),
                            range: 150...1000, low: "Fast", high: "Slow", format: Format.milliseconds,
                            standing: model.standing(of: [["gesture", "repeatIntervalMs"]], in: target))
            }
            .disabled(model.readOnly)
        }
    }
}
