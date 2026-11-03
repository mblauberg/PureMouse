import PureMouseAppSupport
import PureMouseKit
import SwiftUI

struct ButtonsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    /// The control whose picker is open: a button key, or "button.direction".
    @State private var presented: String?
    @State private var highlighted: String?
    /// A control Find by Pressing found that no row lists yet (the mouse has no name for it): it
    /// gets one until Settings closes, so its picker can open.
    @State private var capturedKey: String?
    @State private var sheet: SheetRequest?
    /// Buttons whose Double-click and Hold rows show; collapsed until opened or added.
    @State private var expanded: Set<String> = []
    /// Child rows added from More Ways to Press that do nothing yet ("forward.doubleClick").
    @State private var wanted: Set<String> = []
    @State private var showOthers = false
    @State private var showingAdvanced = false

    static let restoreMessage = "Buttons and gestures return to PureMouse's defaults. App settings don't change."

    /// What Restore Defaults says for one mouse: its own values go, and it follows All Mice.
    static func restoreMessage(for mouse: String) -> String {
        "\(mouse) goes back to the All Mice buttons and gestures. App settings don't change."
    }

    private var scope: ConfigScope { model.scope }
    private var isMouse: Bool { scope.deviceKey != nil }

    var body: some View {
        let usesGestures = model.config.usesGestures
        let scope = model.scope, target = model.scopeTarget
        // What the rows and the card are drawn from, worked out once for this render.
        let named = namedRows, others = otherRows, mouse = cardMouse
        let plan = cardPlan(for: mouse, listing: named)
        ScrollViewReader { proxy in
        PaneForm {
            PaneBanners(needsAccessibility: true)
            if let plan, let mouse {
                Section {
                    DeviceCard(plan: plan, name: mouse.name, actions: cardActions(for: named), selected: card?.button,
                               activate: { settings?.activate($0) })
                }
            }
            Section {
                ForEach(named, id: \.self) { key in row(key) }
                if !others.isEmpty {
                    DisclosureLabel(title: "Other controls", isExpanded: $showOthers)
                    if showOthers {
                        ForEach(others, id: \.self) { key in row(key, indented: true) }
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
        // Choosing a part of the drawing brings its row into view, by request rather than by the
        // highlight: choosing the same part again scrolls to it again.
        .onChange(of: settings?.rowRequest) { _, request in
            guard let request else { return }
            proxy.scrollTo(request.button.rawValue)
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
            if let key = environment["PUREMOUSE_DEV_FOUND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { found(key) }
            }
            // A trigger's picker ("forward.hold") opens with its row's children shown.
            if let key = environment["PUREMOUSE_DEV_PICKER"] {
                if let button = key.split(separator: ".").first, key.contains(".") { expanded.insert(String(button)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presented = key }
            }
            if let key = environment["PUREMOUSE_DEV_EXPAND"] { expanded.insert(key) }
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
        .onChange(of: mouse?.key, initial: true) { _, key in card?.follow(mouse: key) }
        .onChange(of: model.capturedButton) { _, key in
            guard let key else { return }
            model.capturedButton = nil
            if !named.contains(key) {
                capturedKey = key
                showOthers = true
            }
            found(key)
            presented = key
        }
    }

    /// Find by Pressing found `key`: its row is marked for a few seconds, and the drawing lights its
    /// part (`CardSelection.found`), the same state a click on the part gives.
    private func found(_ key: String) {
        highlighted = key
        card?.found(key)
        if let button = NamedButton(rawValue: key) { settings?.requestRow(button) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if highlighted == key { highlighted = nil } }
    }

    // MARK: Rows

    /// Controls the mice in the scope have (nil when none has reported any).
    private var deviceCIDs: Set<UInt16>? {
        let cids = model.reportedControlIDs(in: scope)
        return cids.isEmpty ? nil : Set(cids)
    }

    /// The keys the config binds in this scope, and the control just found that has no row yet.
    private var configKeys: [String] { model.boundButtonKeys(in: scope) + (capturedKey.map { [$0] } ?? []) }

    private var namedRows: [String] {
        ButtonRows.named(deviceCIDs: deviceCIDs, configKeys: configKeys).map(\.rawValue)
    }

    private var card: CardSelection? { settings?.card }

    /// The mouse the device card draws: the chosen one, else the only one known.
    private var cardMouse: KnownMouse? {
        DeviceCardPlan.mouse(selected: model.selectedMouse, known: model.knownMice,
                             unidentified: model.hasUnidentifiedMouse)
    }

    /// The card's parts, from what the mouse has and what Scrolling shows for it; nil for a mouse
    /// with no drawing (a trackball, a vertical mouse, an unknown one: its rows are all it has).
    private func cardPlan(for mouse: KnownMouse?, listing named: [String]) -> DeviceCardPlan? {
        guard let mouse, let art = DeviceArt.model(forKey: mouse.key) else { return nil }
        let layout = ScrollingLayout(config: model.config, devices: model.capabilityDevices(in: scope), scope: scope)
        return DeviceCardPlan(model: art, listed: Set(named.compactMap { NamedButton(rawValue: $0) }),
                              mainWheelSettings: !layout.mainWheelRows.isEmpty, thumbWheelSettings: layout.showsThumbWheel)
    }

    /// Each listed button's action, as its row shows it and as VoiceOver says it.
    private func cardActions(for named: [String]) -> [NamedButton: DeviceCardPlan.ActionText] {
        var actions: [NamedButton: DeviceCardPlan.ActionText] = [:]
        for key in named {
            guard let button = NamedButton(rawValue: key) else { continue }
            let action = shownAction(key)
            actions[button] = .init(shown: ActionButton.shortened(action.label), spoken: action.spokenLabel)
        }
        return actions
    }

    /// The action a row shows for a button: its click, the mouse's own, else what it inherits.
    private func shownAction(_ key: String) -> ButtonAction {
        model.config.scopedButton(key, in: scope).effectiveClick
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

    /// A button's rows (`TriggerRows`): on a mouse, what applies, shown as in All Mice; with its
    /// own, the row says "Set for this mouse." (`InheritedValue`, as on an app's page).
    private func row(_ key: String, indented: Bool = false) -> some View {
        let state = model.config.scopedButton(key, in: scope)
        return TriggerRows(
            key: key, state: state, source: isMouse ? InheritedScope.allMice : nil, help: caption(key),
            spokenSuffix: isMouse ? ", \(model.selectedMouse?.name ?? "")" : "",
            indented: indented, mark: RowMark.of(key, selected: card?.button, found: highlighted),
            // On a mouse, Mouse Default is its own value ("default") beside "Same as All Mice".
            offersMouseDefault: PickerEntry.offersMouseDefault(for: key, inMouseOrApp: isMouse, current: state.click),
            doubleClickMs: model.config.doubleClickMilliseconds(systemSeconds: ConfigTree.systemDoubleClickSeconds),
            scope: scope, expanded: $expanded, wanted: $wanted, presented: $presented,
            choose: { entry, target, current in choose(entry, for: target, current: current) },
            opened: { target in if let button = NamedButton(rawValue: target.button) { card?.select(button) } })
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        highlighted = nil
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture: apply(.gesture, to: target)
        case .trigger: break  // `TriggerRows` adds the row
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
            if let trigger = target.direction {
                $0.bindTrigger(target.button, trigger, to: action, in: scope)
            } else {
                $0.bindClick(target.button, to: action, in: scope)
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
