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

    var body: some View {
        let usesGestures = model.config.usesGestures
        PaneForm {
            PaneBanners(needsAccessibility: true)
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
                PaneFooter(restoreDefaults: { model.update { $0.restoreButtonDefaults() } },
                           restoreMessage: Self.restoreMessage,
                           advanced: usesGestures ? { showingAdvanced = true } : nil)
            }
            .disabled(model.readOnly)
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
        .onChange(of: model.capturedButton) { _, key in
            guard let key else { return }
            model.capturedButton = nil
            if !namedRows.contains(key) { showOthers = true }
            highlighted = key
            presented = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if highlighted == key { highlighted = nil } }
        }
    }

    // MARK: Rows

    /// Controls the connected mice have (nil when no mouse has reported any).
    private var deviceCIDs: Set<UInt16>? {
        let controls = model.devices.flatMap(\.controls)
        return controls.isEmpty ? nil : Set(controls.map(\.cid))
    }

    private var configKeys: [String] { (model.config[["buttons"]] as? [String: Any]).map { Array($0.keys) } ?? [] }

    private var namedRows: [String] {
        ButtonRows.named(deviceCIDs: deviceCIDs, configKeys: configKeys).map(\.rawValue)
    }

    private var otherRows: [String] {
        ButtonRows.others(deviceCIDs: model.devices.flatMap(\.controls).map(\.cid), configKeys: configKeys)
    }

    /// Where an "Other controls" entry lives, for its help line.
    private func caption(_ key: String) -> String? {
        guard NamedButton(rawValue: key) == nil, let cid = NamedButton.cid(forKey: key) else { return nil }
        // No devices: none connected, or paused (the daemon then reports none).
        guard !model.devices.isEmpty else { return nil }
        let owners = model.devices.filter { $0.controls.contains { $0.cid == cid } }.map(\.name)
        return owners.isEmpty ? "Not on the connected mouse" : owners.joined(separator: ", ")
    }

    @ViewBuilder
    private func row(_ key: String, indented: Bool = false) -> some View {
        let action = model.config.binding(key)
        if action == .gesture {
            let isExpanded = Binding(get: { expanded.contains(key) },
                                     set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
            LabeledContent {
                actionButton(action, target: BindingTarget(button: key))
            } label: {
                DisclosureLabel(title: NamedButton.title(forKey: key), help: model.config.gestureSummary(key), isExpanded: isExpanded)
            }
            .padding(.leading, indented ? 16 : 0)
            .listRowBackground(rowFill(key))
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
            }
            .padding(.leading, indented ? 16 : 0)
            .listRowBackground(rowFill(key))
        }
    }

    /// The row Find by Pressing found, for a few seconds: the system's selection fill.
    private func rowFill(_ key: String) -> Color? {
        highlighted == key ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : nil
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        return ActionButton(
            action: isDirection && action == .standard ? .named("none") : action,
            allowsDefault: !isDirection,
            allowsGesture: !isDirection,
            isPresented: Binding(get: { presented == id }, set: { presented = $0 ? id : nil }),
            choose: { entry in choose(entry, for: target, current: action) },
            accessibilityName: target.title)
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
        model.update {
            if let direction = target.direction {
                $0.bind(target.button, direction: direction, to: action)
            } else {
                $0.bind(target.button, to: action)
            }
        }
    }
}

/// Buttons' Advanced… sheet: how Hold and Move feels.
private struct ButtonsAdvancedSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AdvancedSheet(title: "Advanced") {
            Section("Hold and Move") {
                ValueSlider(title: "Distance", help: "How far to move while holding before a direction fires.",
                            value: model.number(["gesture", "distanceMm"], default: 4, step: 0.5),
                            range: 2...12, low: "Short", high: "Long", format: Format.millimetres)
                ValueSlider(title: "Repeat", help: "Keep moving to repeat, such as across several Spaces.",
                            value: model.number(["gesture", "repeatIntervalMs"], default: 400, step: 50),
                            range: 150...1000, low: "Fast", high: "Slow", format: Format.milliseconds)
            }
            .disabled(model.readOnly)
        }
    }
}
