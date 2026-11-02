import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// One app's settings (`apps.<key>`), in a sheet over the Apps list: its icon, name and bundle ID,
/// then its buttons, thumb wheel and scrolling. Settings apply live, so Done closes it; Remove…
/// asks first. No sheet opens from it (docs/ui-design.md, Disclosure): the action picker and the
/// shortcut and command editors are popovers (`EditorPresentation`), and gesture directions,
/// other controls and more thumb wheel options are disclosures. A value the app leaves unset shows
/// what applies everywhere, dimmed (`InheritedValue`).
struct AppSheet: View {
    @Environment(AppModel.self) private var model
    /// The app's key under `apps`.
    let key: String
    let identity: AppIdentities.Identity
    /// Runs once Remove… is confirmed: removes the app's entry and closes the sheet.
    let remove: () -> Void

    @State private var presented: String?
    @State private var editor: SheetRequest?
    @State private var expanded: Set<String> = []
    @State private var showOthers = false
    @State private var confirmingRemove = false

    private var scope: [String] { ConfigTree.appScope(key) }
    private var spoken: String { " in \(identity.name)" }

    /// The binding of `button` (or one `direction` of it) in this app, which names the app in
    /// the editors' subtitles ("in Safari").
    private func bindingTarget(_ button: String, direction: String? = nil) -> BindingTarget {
        BindingTarget(button: button, direction: direction, app: key, appName: identity.name)
    }

    var body: some View {
        let config = model.config
        AdvancedSheet(title: identity.name) {
            Section {
                HStack(spacing: 12) {
                    AppIcon(identity: identity, size: 32)
                    Text(identity.installed ? key : "\(key) (not installed)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let suggestion = suggestion(config) {
                Section {
                    Banner(title: "Suggested for \(identity.name)", message: "The thumb wheel \(describe(suggestion)).",
                           symbol: "lightbulb.fill") {
                        Button("Use Suggested Settings") {
                            model.update { $0.chooseThumbWheel(suggestion.choice, at: scope + ["thumbWheel"], base: globalThumbWheel(config)) }
                        }
                    }
                }
            }

            Section("Buttons") {
                ForEach(namedRows(config), id: \.self) { button in row(button, config) }
                let others = otherRows(config)
                if !others.isEmpty {
                    DisclosureLabel(title: "Other controls", isExpanded: $showOthers)
                    if showOthers {
                        ForEach(others, id: \.self) { button in row(button, config, indented: true) }
                    }
                }
            }
            .disabled(model.readOnly)

            let thumbWheel = ControlAvailability.of([\.thumbWheel], devices: model.capabilityDevices,
                                                    configured: config.contains(scope + ["thumbWheel"]))
            if thumbWheel.isShown {
                Section("Thumb Wheel") {
                    ThumbWheelRows(path: scope + ["thumbWheel"], base: globalThumbWheel(config),
                                   inherited: config.thumbWheelChoice(at: ["thumbWheel"]), appName: identity.name,
                                   availability: thumbWheel)
                }
                .disabled(model.readOnly)
            }

            scrolling(config)
                .disabled(model.readOnly)
        } leading: {
            Button("Remove…") { confirmingRemove = true }
                .disabled(model.readOnly)
                .accessibilityLabel("Remove \(identity.name)'s settings")
        }
        .environment(\.editorPresentation, .popover)
        .removeAppAlert(name: identity.name, isPresented: $confirmingRemove, remove: remove)
        #if DEBUG
        .onAppear {
            // With PUREMOUSE_DEV_APP: opens a button's shortcut editor over the sheet.
            if let button = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_SHORTCUT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    editor = SheetRequest(kind: .shortcut, target: bindingTarget(button), initial: "cmd+w")
                }
            }
        }
        #endif
    }

    // MARK: Suggestion

    private func globalThumbWheel(_ config: ConfigTree) -> ThumbWheelState { config.thumbWheel(at: ["thumbWheel"]) }

    /// A suggestion worth offering: the app leaves the thumb wheel to the global setting, and
    /// the suggestion would change what it does.
    private func suggestion(_ config: ConfigTree) -> AppSuggestion? {
        guard let suggestion = AppSuggestion.forApp(key),
              config.thumbWheelChoice(at: scope + ["thumbWheel"]) == .inherit,
              config.thumbWheelChoice(at: ["thumbWheel"]) != suggestion.choice else { return nil }
        return suggestion
    }

    private func describe(_ suggestion: AppSuggestion) -> String {
        switch suggestion.thumbWheel {
        case "tabs": "switches tabs"
        case "volume": "changes the volume"
        case "zoom": "zooms in and out"
        case "spaces": "moves between Spaces"
        default: "scrolls sideways"
        }
    }

    // MARK: Buttons

    /// The named buttons the connected mice have (those listed by default when none has
    /// reported), plus any bound globally or in this app.
    private func namedRows(_ config: ConfigTree) -> [String] {
        let controls = model.devices.flatMap(\.controls)
        let deviceCIDs = controls.isEmpty ? nil : Set(controls.map(\.cid))
        return ButtonRows.named(deviceCIDs: deviceCIDs, configKeys: configKeys(config)).map(\.rawValue)
    }

    private func otherRows(_ config: ConfigTree) -> [String] {
        ButtonRows.others(deviceCIDs: model.devices.flatMap(\.controls).map(\.cid), configKeys: configKeys(config))
    }

    private func configKeys(_ config: ConfigTree) -> [String] {
        [["buttons"], scope + ["buttons"]].flatMap { (config[$0] as? [String: Any]).map { Array($0.keys) } ?? [] }
    }

    private func title(_ button: String) -> String { NamedButton.title(forKey: button) }

    /// What applies everywhere, for the dimmed value and "Same as Everywhere (…)". An unset
    /// direction does nothing.
    private func everywhereLabel(_ action: ButtonAction, direction: Bool = false, spoken: Bool = false) -> String {
        let action = action == .standard && direction ? ButtonAction.named("none") : action
        return spoken ? action.spokenLabel : action.label
    }

    @ViewBuilder
    private func row(_ button: String, _ config: ConfigTree, indented: Bool = false) -> some View {
        let state = config.appButton(key, button: button)
        let target = bindingTarget(button)
        let everywhere = everywhereLabel(state.everywhere)
        let spokenEverywhere = everywhereLabel(state.everywhere, spoken: true)
        let caption = ActionButton.inherited(state.own, everywhere: everywhere).caption
        if state.directions.isEmpty {
            LabeledContent {
                actionButton(state.own, target: target, sameAsEverywhere: everywhere, spokenEverywhere: spokenEverywhere)
            } label: {
                RowLabel(title(button), help: caption)
            }
            .padding(.leading, indented ? 16 : 0)
            .actionEditorPopover($editor, for: target, save: apply)
        } else {
            // A gesture of the app's own, or one set everywhere that the app inherits: its
            // directions start collapsed, and expanding them writes nothing.
            let isExpanded = Binding(get: { expanded.contains(button) },
                                     set: { if $0 { expanded.insert(button) } else { expanded.remove(button) } })
            LabeledContent {
                actionButton(state.own, target: target, sameAsEverywhere: everywhere, spokenEverywhere: spokenEverywhere)
            } label: {
                DisclosureLabel(title: title(button), help: caption, spokenTitle: "\(title(button)) directions",
                                isExpanded: isExpanded)
            }
            .padding(.leading, indented ? 16 : 0)
            .actionEditorPopover($editor, for: target, save: apply)
            if isExpanded.wrappedValue {
                ForEach(state.directions, id: \.name) { direction in
                    let target = bindingTarget(button, direction: direction.name)
                    // A direction the app leaves out follows the global gesture, if there is one;
                    // else it does nothing.
                    let inherited = direction.everywhere.map { everywhereLabel($0, direction: true) }
                    let spokenInherited = direction.everywhere.map { everywhereLabel($0, direction: true, spoken: true) }
                    let own = direction.own == .standard && inherited == nil ? .named("none") : direction.own
                    LabeledContent {
                        actionButton(own, target: target, sameAsEverywhere: inherited, spokenEverywhere: spokenInherited)
                    } label: {
                        RowLabel(Gesture.label(direction.name),
                                 help: inherited.flatMap { ActionButton.inherited(own, everywhere: $0).caption })
                    }
                    .padding(.leading, indented ? 38 : 22)
                    .actionEditorPopover($editor, for: target, save: apply)
                }
            }
        }
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget, sameAsEverywhere: String?,
                              spokenEverywhere: String?) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        return ActionButton(
            action: action,
            allowsDefault: false,
            allowsGesture: !isDirection,
            isPresented: Binding(get: { presented == id }, set: { presented = $0 ? id : nil }),
            choose: { entry in choose(entry, for: target, current: action) },
            accessibilityName: target.title + spoken,
            sameAsEverywhere: sameAsEverywhere,
            spokenEverywhere: spokenEverywhere)
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture:
            apply(.gesture, to: target)
            expanded.insert(target.button)
        case .shortcut:
            let initial = if case .keys(let spec) = current { spec } else { "" }
            // Let the picker's popover close before the editor's opens.
            DispatchQueue.main.async { editor = SheetRequest(kind: .shortcut, target: target, initial: initial) }
        case .command:
            let initial = if case .run(let command) = current { command } else { "" }
            DispatchQueue.main.async { editor = SheetRequest(kind: .command, target: target, initial: initial) }
        }
    }

    private func apply(_ action: ButtonAction, to target: BindingTarget) {
        model.update {
            if let direction = target.direction {
                $0.bindInApp(key, button: target.button, direction: direction, to: action)
            } else {
                $0.bindInApp(key, button: target.button, to: action)
            }
        }
    }

    // MARK: Scrolling

    private func scrolling(_ config: ConfigTree) -> some View {
        let custom = config.overridesScrolling(key)
        let speedPath = scope + ["smoothScroll", "speed"]
        let glidePath = scope + ["smoothScroll", "smoothingMs"]
        let globalSpeed = config.double(["smoothScroll", "speed"]) ?? 1
        let globalGlide = config.double(["smoothScroll", "smoothingMs"]) ?? 125
        return Section("Scrolling") {
            Toggle(isOn: Binding(get: { custom }, set: { on in model.update { $0.setOverridesScrolling(key, on) } })) {
                RowLabel("Custom scrolling", help: config.customScrollingCaption(key))
            }
            .accessibilityLabel("Custom scrolling\(spoken)")
            // The rows appear only while on, so nothing is written until the app has its own values.
            if custom {
                ValueSlider(title: "Speed", spokenTitle: "Scrolling speed\(spoken)",
                            value: model.number(speedPath, default: globalSpeed, step: 0.05),
                            range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier)
                    .disclosedRow()
                ValueSlider(title: "Glide", spokenTitle: "Glide\(spoken)", help: "0 scrolls instantly.",
                            value: model.number(glidePath, default: globalGlide, step: 25),
                            range: 0...500, low: "Short", high: "Long", format: Format.milliseconds)
                    .disabled(!config.scrollsSmoothly(key))
                    .disclosedRow()
            }
        }
    }
}

extension View {
    /// Asks before removing an app's settings: a system alert whose Remove is a plain verb button
    /// (chosen on purpose, so not the destructive style) and whose Cancel is not the default.
    func removeAppAlert(name: String, isPresented: Binding<Bool>, remove: @escaping () -> Void) -> some View {
        alert("Remove \(name)'s settings?", isPresented: isPresented) {
            Button("Remove", action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its buttons, thumb wheel and scrolling go back to the settings used everywhere.")
        }
    }
}
