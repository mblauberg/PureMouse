import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// One app's settings (`apps.<key>`) as a page of the Apps tab, in place of its list: a header
/// strip (‹ Apps, the Buttons and Scrolling segments, the app) above the segment's grouped form, as
/// the Mouse tab draws its own (`MouseHeader`). Settings apply live, so there is no Done: ‹ Apps,
/// ⌘[ and Esc go back, and Remove App… at the footer's leading edge asks first. The editors open
/// as sheets. A value the app leaves unset looks as the mice resolve it, or says "Varies by Mouse"
/// when they differ; one it sets says "Set for this app." (`InheritedValue`). Choosing a segment
/// writes nothing, and the page has no Pointer: an app sets buttons, the thumb wheel and scrolling.
struct AppPage: View {
    @Environment(AppModel.self) private var model
    /// The app's key under `apps`.
    let key: String
    let identity: AppIdentities.Identity
    let segment: AppSegment
    let select: (AppSegment) -> Void
    /// ‹ Apps, ⌘[ and Esc.
    let back: () -> Void
    /// Runs once Remove App… is confirmed: removes the app's entry and closes the page.
    let remove: () -> Void

    @Environment(\.settings) private var settings
    @Environment(\.paneMaxHeight) private var paneMaxHeight
    /// The header's height as drawn, which the form's cap leaves room for (about the Mouse tab's strip).
    @State private var headerHeight: CGFloat = 40
    @State private var presented: String?
    @State private var editor: SheetRequest?
    @State private var expanded: Set<String> = []
    /// Child rows added from More Ways to Press that do nothing yet ("forward.doubleClick").
    @State private var wanted: Set<String> = []
    @State private var showOthers = false
    @State private var confirmingRemove = false

    private var scope: [String] { ConfigTree.appScope(key).prefix }
    private var spoken: String { " in \(identity.name)" }
    /// The mice the app's unset settings fall back to.
    private var mice: [ConfigScope] { model.appInheritedScopes }

    /// The binding of `button` (or one `direction` of it) in this app, which names the app in
    /// the editors' subtitles ("in Safari").
    private func bindingTarget(_ button: String, direction: String? = nil) -> BindingTarget {
        BindingTarget(button: button, direction: direction, app: key, appName: identity.name)
    }

    var body: some View {
        // The header is a view of its own above the form, as the Mouse tab's strip is above its
        // pane (`MouseTab`): the form scrolls beneath it, and no scroll-edge line is drawn under it.
        // The form is capped to what the pane's limit leaves below the header, so the two together
        // never pass it.
        VStack(spacing: 0) {
            AppPageHeader(key: key, identity: identity, segment: segment, select: select, back: back)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            PaneForm {
                switch segment {
                case .buttons: buttons(model.config)
                case .scrolling: scrolling(model.config)
                }
                Section {} footer: {
                    HStack {
                        Button("Remove App…") { confirmingRemove = true }
                            .accessibilityLabel("Remove \(identity.name)'s settings")
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .disabled(model.readOnly)
            .environment(\.paneMaxHeight, max(paneMaxHeight - headerHeight, 0))
        }
        .actionEditorSheet($editor) { action, target in apply(action, to: target) }
        .removeAppAlert(name: identity.name, isPresented: $confirmingRemove, remove: remove)
        // Gesture directions, other controls and more thumb wheel options change the page's height.
        .onChange(of: expanded) { settings?.refit() }
        .onChange(of: showOthers) { settings?.refit() }
        .onChange(of: headerHeight) { settings?.refit() }
        #if DEBUG
        .onAppear {
            // With PUREMOUSE_DEV_APP: PUREMOUSE_DEV_OTHERS=1 opens "Other controls",
            // PUREMOUSE_DEV_EXPAND=<button> shows a button's Double-click and Hold rows, and
            // PUREMOUSE_DEV_SHORTCUT opens a button's shortcut editor sheet over the page.
            if ProcessInfo.processInfo.environment["PUREMOUSE_DEV_OTHERS"] != nil { showOthers = true }
            if let button = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_EXPAND"] { expanded.insert(button) }
            if let button = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_SHORTCUT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    editor = SheetRequest(kind: .shortcut, target: bindingTarget(button), initial: "cmd+w")
                }
            }
        }
        #endif
    }

    // MARK: Buttons

    @ViewBuilder
    private func buttons(_ config: ConfigTree) -> some View {
        PaneBanners(needsAccessibility: true)
        Section {
            ForEach(namedRows(config), id: \.self) { button in row(button, config) }
            let others = otherRows(config)
            if !others.isEmpty {
                DisclosureLabel(title: "Other controls", isExpanded: $showOthers)
                if showOthers {
                    ForEach(others, id: \.self) { button in row(button, config, indented: true) }
                }
            }
        }
    }

    /// The named buttons the connected mice have (those listed by default when none has
    /// reported), plus any bound in the mice or in this app.
    private func namedRows(_ config: ConfigTree) -> [String] {
        let controls = model.devices.flatMap(\.controls)
        let deviceCIDs = controls.isEmpty ? nil : Set(controls.map(\.cid))
        return ButtonRows.named(deviceCIDs: deviceCIDs, configKeys: configKeys(config)).map(\.rawValue)
    }

    private func otherRows(_ config: ConfigTree) -> [String] {
        ButtonRows.others(deviceCIDs: model.devices.flatMap(\.controls).map(\.cid), configKeys: configKeys(config))
    }

    /// The keys under `buttons` that make a control listed: Mouse Settings', each mouse's own, and
    /// the app's (the Mouse tab lists the top level's and the mouse's: `AppModel.boundButtonKeys`).
    private func configKeys(_ config: ConfigTree) -> [String] {
        let prefixes = [[]] + mice.map { config.prefix(of: $0) } + [scope]
        return prefixes.flatMap { (config[$0 + ["buttons"]] as? [String: Any]).map { Array($0.keys) } ?? [] }
    }

    private func title(_ button: String) -> String { NamedButton.title(forKey: button) }

    /// A button's rows (`TriggerRows`, as on the Mouse tab): the app's own triggers over what the
    /// mice give it. Expanding a row writes nothing.
    private func row(_ button: String, _ config: ConfigTree, indented: Bool = false) -> some View {
        let state = config.appButton(key, button: button, inheriting: mice)
        return TriggerRows(
            key: button, state: state, source: InheritedScope.mouseSettings, spokenSuffix: spoken, indented: indented,
            offersMouseDefault: PickerEntry.offersMouseDefault(for: button, inMouseOrApp: true, current: state.click),
            doubleClickMs: config.doubleClickMilliseconds(systemSeconds: ConfigTree.systemDoubleClickSeconds),
            expanded: $expanded, wanted: $wanted, presented: $presented,
            choose: { entry, target, current in choose(entry, for: bindingTarget(target.button, direction: target.direction),
                                                       current: current) })
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture: apply(.gesture, to: target)
        case .trigger: break  // `TriggerRows` adds the row
        case .shortcut:
            let initial = if case .keys(let spec) = current { spec } else { "" }
            // Let the picker's popover close before the editor's sheet opens.
            DispatchQueue.main.async { editor = SheetRequest(kind: .shortcut, target: target, initial: initial) }
        case .command:
            let initial = if case .run(let command) = current { command } else { "" }
            DispatchQueue.main.async { editor = SheetRequest(kind: .command, target: target, initial: initial) }
        }
    }

    private func apply(_ action: ButtonAction, to target: BindingTarget) {
        let scope = ConfigTree.appScope(key), mice = mice
        model.update {
            if let trigger = target.direction {
                $0.bindTrigger(target.button, trigger, to: action, in: scope, inheriting: mice)
            } else {
                $0.bindClick(target.button, to: action, in: scope, inheriting: mice)
            }
        }
    }

    // MARK: Scrolling

    @ViewBuilder
    private func scrolling(_ config: ConfigTree) -> some View {
        PaneBanners(needsAccessibility: true)
        if let suggestion = suggestion(config) {
            // An ordinary form row, as System Settings draws a suggestion: the words, and a bordered
            // button at the trailing edge.
            Section {
                LabeledContent {
                    Button("Use Suggested Settings") {
                        model.update { $0.chooseThumbWheel(suggestion.choice, at: scope + ["thumbWheel"], base: config.thumbWheelState(inheriting: mice).first) }
                    }
                    .buttonStyle(.bordered)
                } label: {
                    RowLabel("Suggested for \(identity.name)", help: "The thumb wheel \(describe(suggestion)).")
                }
            }
        }
        customScrolling(config)
        let thumbWheel = ControlAvailability.of([\.thumbWheel], devices: model.capabilityDevices,
                                                configured: config.contains(scope + ["thumbWheel"]))
        if thumbWheel.isShown {
            let choice = config.thumbWheelChoice(inheriting: mice)
            let states = config.thumbWheelState(inheriting: mice)
            Section("Thumb Wheel") {
                ThumbWheelRows(path: scope + ["thumbWheel"], base: states.first, bases: states.values,
                               inherited: choice.first, inheritedVaries: config.thumbWheelVaries(inheriting: mice),
                               inheritedVariesKeys: config.thumbWheelKeysVarying(inheriting: mice, ownPath: scope + ["thumbWheel"]), appName: identity.name,
                               availability: thumbWheel)
            }
        }
    }

    // MARK: Suggestion

    /// A suggestion worth offering: the app leaves the thumb wheel to the mice, and the suggestion
    /// would change what it does on each of them.
    private func suggestion(_ config: ConfigTree) -> AppSuggestion? {
        guard let suggestion = AppSuggestion.forApp(key),
              config.thumbWheelChoice(at: scope + ["thumbWheel"]) == .inherit,
              !config.thumbWheelChoice(inheriting: mice).values.contains(suggestion.choice) else { return nil }
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

    // MARK: Custom scrolling

    /// A value the app sets under `apps.<key>` stands against Mouse Settings: marked while the app
    /// holds it, and given back by removing the key (the last one turns Custom scrolling off).
    private func appStanding(_ path: [String], _ config: ConfigTree) -> RowStanding {
        RowStanding(source: InheritedScope.mouseSettings, isOwn: config.contains(path)) {
            model.update { $0.set(nil, at: path) }
        }
    }

    private func customScrolling(_ config: ConfigTree) -> some View {
        let custom = config.overridesScrolling(key)
        let speedPath = scope + ["smoothScroll", "speed"]
        let glidePath = scope + ["smoothScroll", "smoothingMs"]
        // Left to the mice, a value is theirs: the first one's on the slider, and "Varies" (VoiceOver:
        // "Varies by Mouse") for the number while they differ. The short word fits the readout the
        // slider rows share, so the track stays where it is on Mouse › Scrolling.
        let speed = config.appliedNumber(["smoothScroll", "speed"], inheriting: mice, default: 1)
        let glide = config.appliedNumber(["smoothScroll", "smoothingMs"], inheriting: mice, default: 125)
        let speedVaries = speed.varies && !config.contains(speedPath)
        let glideVaries = glide.varies && !config.contains(glidePath)
        return Section {
            Toggle(isOn: Binding(get: { custom }, set: { on in model.update { $0.setOverridesScrolling(key, on, inheriting: mice) } })) {
                RowLabel("Custom scrolling", help: ConfigTree.customScrollingCaption)
            }
            .accessibilityLabel("Custom scrolling\(spoken)")
            // The rows appear only while on, so nothing is written until the app has its own values.
            if custom {
                ValueSlider(title: "Speed", spokenTitle: "Scrolling speed\(spoken)",
                            value: model.number(speedPath, default: speed.first, step: 0.05),
                            range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier,
                            standing: appStanding(speedPath, config),
                            variesText: speedVaries ? Applied<Double>.variesLabel : nil)
                    .disclosedRow()
                ValueSlider(title: "Glide", spokenTitle: "Glide\(spoken)", help: "Short glides stop sooner.",
                            value: model.number(glidePath, default: glide.first, step: 25),
                            range: 0...500, low: "Short", high: "Long", format: Format.milliseconds,
                            standing: appStanding(glidePath, config),
                            variesText: glideVaries ? Applied<Double>.variesLabel : nil)
                    .disabled(!config.scrollsSmoothly(key, inheriting: mice))
                    .disclosedRow()
            }
        }
    }
}

/// The strip above an app's page, drawn as the Mouse tab's (`MouseHeader`): ‹ Apps at the leading
/// edge, the segments in the middle, and the app at the trailing edge. ⌘[ and Esc go back too; Esc
/// is a hidden button's cancel action, since a button holds one shortcut.
struct AppPageHeader: View {
    let key: String
    let identity: AppIdentities.Identity
    let segment: AppSegment
    let select: (AppSegment) -> Void
    let back: () -> Void

    /// The strip's top inset, which is what `.padding(.top)` gives on macOS, as `MouseHeader` has it.
    static let topInset: CGFloat = 16

    var body: some View {
        // Each side is a slot that shares what is left equally, so the segments stay in the middle
        // and a long app name is cut with an ellipsis instead of overlapping them.
        HStack {
            HStack(spacing: 0) {
                Button(action: back) {
                    Label("Apps", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Apps (⌘[)")
                .accessibilityLabel("Back to Apps")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Picker("App settings", selection: Binding(get: { segment }, set: { select($0) })) {
                ForEach(AppSegment.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                AppIcon(identity: identity, size: 20)
                Text(identity.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(identity.installed ? key : "\(key) (not installed)")
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("App")
            .accessibilityValue(identity.name)
        }
        // In line with the grouped boxes below, whose form insets them by the same margin.
        .padding(.horizontal, 20)
        // A fixed inset, with the strip at its own height: neither is left to the first
        // `sizeThatFits` pass, which has placed the strip 8 pt lower in one layout than another.
        .padding(.top, Self.topInset)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .overlay {
            Button(action: back) { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                // Not a stop for Tab: it only holds Esc.
                .focusable(false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
            Text("Its buttons, thumb wheel and scrolling go back to Mouse Settings.")
        }
    }
}
