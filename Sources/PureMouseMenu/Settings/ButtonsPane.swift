import PureMouseKit
import SwiftUI

struct ButtonsPane: View {
    @Environment(AppModel.self) private var model
    /// The control whose picker is open: a button key, or "button.direction".
    @State private var presented: String?
    @State private var highlighted: String?
    @State private var sheet: SheetRequest?
    @State private var expanded: Set<String> = ["gesture"]
    @State private var showOthers = false

    var body: some View {
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
                HStack {
                    Text("Buttons")
                    Spacer()
                    if model.captureListening {
                        Text("Press a button on your mouse")
                            .foregroundStyle(.secondary)
                            .fontWeight(.regular)
                        Button("Cancel") { model.cancelCapture() }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Select by Pressing") { model.startCapture() }
                            .disabled(!model.daemonRunning || model.paused || model.readOnly)
                            .help(model.daemonRunning ? "Press a mouse button to find its row" : "PureMouse is off")
                    }
                }
            }
            .disabled(model.readOnly)

            Section {
                ValueSlider(title: "Distance", help: "How far to move while holding before a direction fires.",
                            value: model.number(["gesture", "distanceMm"], default: 4, step: 0.5),
                            range: 2...12, low: "Short", high: "Long", format: Format.millimetres)
                ValueSlider(title: "Repeat", help: "Keep moving to repeat, such as across several Spaces.",
                            value: model.number(["gesture", "repeatIntervalMs"], default: 400, step: 50),
                            range: 150...1000, low: "Fast", high: "Slow", format: Format.milliseconds)
            } header: {
                    Text("Gesture feel")
                } footer: {
                FooterButton("Restore Defaults") {
                    model.update {
                        $0.set(nil, at: ["buttons"])
                        $0.set(nil, at: ["gesture"])
                    }
                }
            }
            .disabled(model.readOnly)
        }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .shortcut: ShortcutSheet(request: request) { apply(.keys($0), to: request.target) }
            case .command: CommandSheet(request: request) { apply(.run($0), to: request.target) }
            }
        }
        #if DEBUG
        .onAppear {
            let environment = ProcessInfo.processInfo.environment
            if let key = environment["PUREMOUSE_DEV_PICKER"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presented = key }
            }
            if let key = environment["PUREMOUSE_DEV_SHORTCUT"] {
                sheet = SheetRequest(kind: .shortcut, target: BindingTarget(button: key), initial: "cmd+w")
            }
        }
        #endif
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

    /// Controls the connected mice have (all five names when no mouse has reported any), plus any
    /// the config binds.
    private var deviceCIDs: Set<UInt16>? {
        let controls = model.devices.flatMap(\.controls)
        return controls.isEmpty ? nil : Set(controls.map(\.cid))
    }

    private var configKeys: [String] { (model.config[["buttons"]] as? [String: Any]).map { Array($0.keys) } ?? [] }

    private var namedRows: [String] {
        NamedButton.allCases.filter { button in
            deviceCIDs.map { $0.contains(button.cid) } ?? true || configKeys.contains(button.rawValue)
        }.map(\.rawValue)
    }

    private var otherRows: [String] {
        let named = Set(NamedButton.allCases.map(\.cid))
        var keys = Set(model.devices.flatMap(\.controls).filter { !named.contains($0.cid) }.map { NamedButton.hex($0.cid) })
        for key in configKeys where NamedButton(rawValue: key) == nil {
            if let cid = NamedButton.cid(forKey: key), !keys.contains(NamedButton.hex(cid)) { keys.insert(key) }
        }
        return keys.sorted()
    }

    private func title(_ key: String) -> String {
        NamedButton(rawValue: key)?.label ?? "Control \(key)"
    }

    /// Where an "Other controls" entry lives, for its help line.
    private func caption(_ key: String) -> String? {
        guard NamedButton(rawValue: key) == nil, let cid = NamedButton.cid(forKey: key) else { return nil }
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
                DisclosureLabel(title: title(key), help: caption(key), isExpanded: isExpanded)
            }
            .padding(.leading, indented ? 16 : 0)
            if isExpanded.wrappedValue {
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
                RowLabel(title(key), help: caption(key))
            }
            .padding(.leading, indented ? 16 : 0)
        }
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        return ActionButton(
            action: isDirection && action == .standard ? .named("none") : action,
            allowsDefault: !isDirection,
            allowsGesture: !isDirection,
            highlighted: highlighted == id,
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
