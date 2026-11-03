import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// One app's settings (`apps.<key>`) as a page of the Apps tab, in place of its list: a header
/// strip (‹ Apps, the Buttons and Scrolling segments, the app) over the segment's grouped form, as
/// the Mouse tab draws its own (`MouseHeader`). Settings apply live, so there is no Done: ‹ Apps,
/// ⌘[ and Esc go back, and Remove App… at the footer's leading edge asks first. The editors open
/// as sheets. A value the app leaves unset looks as the mice resolve it, or says "Varies by Mouse"
/// when they differ; one it sets says "Set for this app." (`InheritedValue`). Choosing a segment
/// writes nothing, and the page has no Pointer: an app sets buttons, the thumb wheel and scrolling.
struct AppPage: View {
    /// The header strip's height, with the margin under it, which the form's cap leaves room for.
    private static let headerHeight: CGFloat = 60

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
    @State private var presented: String?
    @State private var editor: SheetRequest?
    @State private var expanded: Set<String> = []
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

    /// The screen's height less the window's toolbar and the page's header strip.
    private static var maxFormHeight: CGFloat {
        LazyPane.fitted(NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)).height - headerHeight
    }

    var body: some View {
        // The form is the root, as in every other pane, and the header an inset above it that stays
        // in view as the form scrolls. A stack of the two let the window grow past the screen.
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
        // As tall as its rows, up to what the screen leaves, then it scrolls (as `AdvancedSheet`'s
        // form does). Left to be proposed the window's height, the form read as unbounded now and
        // then and took the window past the screen.
        .frame(maxHeight: Self.maxFormHeight)
        .fixedSize(horizontal: false, vertical: true)
        .softTopEdge()
        .safeAreaInset(edge: .top, spacing: 0) {
            AppPageHeader(key: key, identity: identity, segment: segment, select: select, back: back)
        }
        // At the top, as the Mouse tab's panes are, whatever height the window has.
        .frame(maxHeight: .infinity, alignment: .top)
        .actionEditorSheet($editor) { action, target in apply(action, to: target) }
        .removeAppAlert(name: identity.name, isPresented: $confirmingRemove, remove: remove)
        // Gesture directions, other controls and more thumb wheel options change the page's height.
        .onChange(of: expanded) { settings?.refit() }
        .onChange(of: showOthers) { settings?.refit() }
        #if DEBUG
        .onAppear {
            // With PUREMOUSE_DEV_APP: PUREMOUSE_DEV_OTHERS=1 opens "Other controls", and
            // PUREMOUSE_DEV_SHORTCUT opens a button's shortcut editor sheet over the page.
            if ProcessInfo.processInfo.environment["PUREMOUSE_DEV_OTHERS"] != nil { showOthers = true }
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

    @ViewBuilder
    private func row(_ button: String, _ config: ConfigTree, indented: Bool = false) -> some View {
        let state = config.appButton(key, button: button, inheriting: mice)
        let target = bindingTarget(button)
        let inherited = state.inheritedLabel
        let spokenInherited = state.inheritedSpokenLabel
        let note = ActionButton.inherited(state.own, everywhere: inherited).note { apply(.standard, to: target) }
        if state.directions.isEmpty {
            LabeledContent {
                actionButton(state.own, target: target, sameAs: inherited, spokenSameAs: spokenInherited)
            } label: {
                RowLabel(title(button), note: note)
            }
            .overridable(note, help: nil)
            .padding(.leading, indented ? 16 : 0)
        } else {
            // A gesture of the app's own, or one the mice set that the app inherits: its
            // directions start collapsed, and expanding them writes nothing.
            let isExpanded = Binding(get: { expanded.contains(button) },
                                     set: { if $0 { expanded.insert(button) } else { expanded.remove(button) } })
            LabeledContent {
                actionButton(state.own, target: target, sameAs: inherited, spokenSameAs: spokenInherited)
            } label: {
                DisclosureLabel(title: title(button), note: note, spokenTitle: "\(title(button)) directions",
                                isExpanded: isExpanded)
            }
            .overridable(note, help: nil)
            .padding(.leading, indented ? 16 : 0)
            if isExpanded.wrappedValue {
                ForEach(state.directions, id: \.name) { direction in
                    let target = bindingTarget(button, direction: direction.name)
                    // A direction the app leaves out follows the mice's gesture, if they have one,
                    // else does nothing; one it sets itself is marked either way.
                    let note = ActionButton.inherited(direction, source: InheritedScope.mouseSettings)
                        .note { apply(.standard, to: target) }
                    LabeledContent {
                        actionButton(direction.own, target: target, sameAs: direction.inheritedLabel,
                                     spokenSameAs: direction.inheritedSpokenLabel)
                    } label: {
                        RowLabel(Gesture.label(direction.name), note: note, spokenTitle: target.title + spoken)
                    }
                    .overridable(note, help: nil)
                    .padding(.leading, indented ? 38 : 22)
                }
            }
        }
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget, sameAs: String?,
                              spokenSameAs: String?) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        return ActionButton(
            action: action,
            allowsDefault: !isDirection && PickerEntry.offersMouseDefault(for: target.button, inMouseOrApp: true, current: action),
            allowsGesture: !isDirection,
            isPresented: Binding(get: { presented == id }, set: { presented = $0 ? id : nil }),
            choose: { entry in choose(entry, for: target, current: action) },
            accessibilityName: target.title + spoken,
            sameAsEverywhere: sameAs,
            spokenEverywhere: spokenSameAs)
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture:
            apply(.gesture, to: target)
            expanded.insert(target.button)
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
        model.update {
            if let direction = target.direction {
                $0.bindInApp(key, button: target.button, direction: direction, to: action)
            } else {
                $0.bindInApp(key, button: target.button, to: action, inheriting: mice)
            }
        }
    }

    // MARK: Scrolling

    @ViewBuilder
    private func scrolling(_ config: ConfigTree) -> some View {
        PaneBanners(needsAccessibility: true)
        if let suggestion = suggestion(config) {
            Section {
                Banner(title: "Suggested for \(identity.name)", message: "The thumb wheel \(describe(suggestion)).",
                       symbol: "lightbulb.fill") {
                    Button("Use Suggested Settings") {
                        model.update { $0.chooseThumbWheel(suggestion.choice, at: scope + ["thumbWheel"], base: config.thumbWheelState(inheriting: mice).first) }
                    }
                }
            }
        }
        customScrolling(config)
        let thumbWheel = ControlAvailability.of([\.thumbWheel], devices: model.capabilityDevices,
                                                configured: config.contains(scope + ["thumbWheel"]))
        if thumbWheel.isShown {
            let choice = config.thumbWheelChoice(inheriting: mice)
            // Mice that both choose Custom may still set different actions.
            let variesDirections = Set(["left", "right"].filter { config.thumbWheelAction($0, inheriting: mice).varies })
            Section("Thumb Wheel") {
                ThumbWheelRows(path: scope + ["thumbWheel"], base: config.thumbWheelState(inheriting: mice).first,
                               inherited: choice.first, inheritedVaries: config.thumbWheelVaries(inheriting: mice),
                               inheritedVariesDirections: variesDirections, appName: identity.name,
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
        // Left to the mice, a value is theirs: the first one's on the slider, and "Varies by Mouse"
        // for the number while they differ.
        let speed = config.appliedNumber(["smoothScroll", "speed"], inheriting: mice, default: 1)
        let glide = config.appliedNumber(["smoothScroll", "smoothingMs"], inheriting: mice, default: 125)
        let speedVaries = speed.varies && !config.contains(speedPath)
        let glideVaries = glide.varies && !config.contains(glidePath)
        return Section {
            Toggle(isOn: Binding(get: { custom }, set: { on in model.update { $0.setOverridesScrolling(key, on, inheriting: mice) } })) {
                RowLabel("Custom scrolling", help: config.customScrollingCaption(key, inheriting: mice))
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
        .padding(.top)
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
    /// A soft fade where the form scrolls under the header strip, not the hard line macOS 26 draws
    /// under an inset: the Mouse tab's strip has no line under it.
    @ViewBuilder func softTopEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }

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
