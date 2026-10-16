import AppKit
import PureMouseKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-app settings (`apps.<bundle id>`): a list of apps, and each app's own buttons, thumb wheel
/// and scrolling speed. Writes only the keys it shows under `apps`; a setting put back to "Same
/// as Everywhere" removes its key, and an app with nothing left is removed (`ConfigTree.set`).
struct AppsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.app) private var app
    /// The app whose settings show, by its key under `apps` (or the bundle ID just added).
    @State private var selected: String?
    /// Apps added here that have no setting yet: nothing is written until one is set.
    @State private var added: [String] = []
    @State private var identities = AppIdentities()
    @State private var removing: String?

    var body: some View {
        Group {
            if let selected {
                AppDetail(key: selected, identity: identities.identity(selected),
                          back: { self.selected = nil }, remove: { removing = selected })
            } else {
                list
            }
        }
        .onChange(of: selected) { app?.refitSettings() }
        .confirmationDialog("Remove \(removing.map { identities.identity($0).name } ?? "this app")'s settings?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing { remove(id) }
            }
        } message: {
            Text("Its buttons, thumb wheel and scrolling go back to the settings used everywhere.")
        }
        #if DEBUG
        .onAppear {
            if let id = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_APP"] { add(id) }
        }
        #endif
    }

    /// The configured apps and those added here, by name.
    private var listed: [String] {
        let config = model.config
        let ids = config.appIDs + added.filter { !config.hasApp($0) }
        return ids.sorted {
            identities.identity($0).name.localizedStandardCompare(identities.identity($1).name) == .orderedAscending
        }
    }

    private var list: some View {
        PaneForm {
            PaneBanners(needsAccessibility: true)
            Section {
                let apps = listed
                if apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("No apps yet").font(.headline)
                        Text("Add an app to give it its own buttons, thumb wheel or scrolling speed.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(apps, id: \.self) { id in
                        AppRow(identity: identities.identity(id), summary: model.config.appSummary(id)) {
                            selected = id
                        }
                        .contextMenu {
                            Button("Remove…") { removing = id }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Apps")
                    Spacer()
                    addMenu
                }
            } footer: {
                Text("Buttons follow the frontmost app. Scrolling and the thumb wheel follow the app under the pointer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.readOnly)
        }
    }

    private var addMenu: some View {
        Menu("Add App") {
            Button("Choose from Applications…") { chooseApp() }
            let running = RunningApp.all(excluding: Set(listed.map { $0.lowercased() }))
            if !running.isEmpty {
                Section("Running") {
                    ForEach(running) { entry in
                        Button(entry.name) { add(entry.id) }
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityHint("Choose an app to give its own settings")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app to give its own buttons, thumb wheel or scrolling speed."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier else {
                Alerts.show("That app cannot be added", "\(url.lastPathComponent) has no bundle identifier.")
                return
            }
            add(id)
        }
        if let window = app?.settingsWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func add(_ bundleID: String) {
        let key = model.config.appKey(bundleID)
        if !model.config.hasApp(key), !added.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            added.append(key)
        }
        selected = key
    }

    private func remove(_ id: String) {
        model.update { $0.removeApp(id) }
        added.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
        removing = nil
        selected = nil
    }
}

/// An app's name and icon, looked up when its row or page first shows and kept for the
/// pane's life (which ends when Settings closes).
@MainActor
final class AppIdentities {
    struct Identity {
        let name: String
        let icon: NSImage
        let installed: Bool
    }

    private var cache: [String: Identity] = [:]

    func identity(_ bundleID: String) -> Identity {
        let key = bundleID.lowercased()
        if let hit = cache[key] { return hit }
        let identity: Identity
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            identity = Identity(name: name, icon: NSWorkspace.shared.icon(forFile: url.path), installed: true)
        } else {
            identity = Identity(name: AppSuggestion.forApp(bundleID)?.name ?? bundleID,
                                icon: NSWorkspace.shared.icon(for: .application), installed: false)
        }
        cache[key] = identity
        return identity
    }
}

/// A running app with a Dock icon, for the Add App menu (read when the pane draws, never watched).
private struct RunningApp: Identifiable {
    let id: String
    let name: String

    @MainActor
    static func all(excluding: Set<String>) -> [RunningApp] {
        var seen = excluding
        seen.insert((Bundle.main.bundleIdentifier ?? "").lowercased())
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, seen.insert(id.lowercased()).inserted else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct AppRow: View {
    let identity: AppIdentities.Identity
    let summary: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: identity.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.name)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.name)
        .accessibilityValue(summary)
        .accessibilityHint("Shows its settings")
        .accessibilityAddTraits(.isButton)
    }
}

/// One app's settings.
private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    /// The app's key under `apps`.
    let key: String
    let identity: AppIdentities.Identity
    let back: () -> Void
    let remove: () -> Void

    @State private var presented: String?
    @State private var sheet: SheetRequest?
    @State private var expanded: Set<String> = ["gesture"]
    @State private var showOthers = false

    private var scope: [String] { ConfigTree.appScope(key) }
    private var spoken: String { " in \(identity.name)" }

    var body: some View {
        let config = model.config
        PaneForm {
            PaneBanners(needsAccessibility: true)
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: identity.icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.name).font(.title3.weight(.semibold))
                        Text(identity.installed ? key : "\(key) (not installed)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Remove…", action: remove)
                        .disabled(model.readOnly)
                        .accessibilityLabel("Remove \(identity.name)'s settings")
                }
            } header: {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                        Text("Apps")
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to Apps")
            }

            if let suggestion = suggestion(config) {
                Section {
                    Banner(title: "Suggested for \(identity.name)", message: "The thumb wheel \(describe(suggestion)).",
                           symbol: "lightbulb.fill", tint: .yellow) {
                        Button("Use Suggested Settings") {
                            model.update { $0.chooseThumbWheel(suggestion.choice, at: scope + ["thumbWheel"], base: globalThumbWheel(config)) }
                        }
                    }
                }
            }

            Section {
                ForEach(namedRows(config), id: \.self) { button in row(button, config) }
                let others = otherRows(config)
                if !others.isEmpty {
                    DisclosureLabel(title: "Other controls", isExpanded: $showOthers)
                    if showOthers {
                        ForEach(others, id: \.self) { button in row(button, config, indented: true) }
                    }
                }
            } header: {
                Text("Buttons")
            }
            .disabled(model.readOnly)

            if model.primaryDevice?.hasThumbWheel != false || config.contains(scope + ["thumbWheel"]) {
                Section("Thumb wheel") {
                    ThumbWheelRows(path: scope + ["thumbWheel"], base: globalThumbWheel(config),
                                   inherited: config.thumbWheelChoice(at: ["thumbWheel"]).label, spokenSuffix: spoken)
                }
                .disabled(model.readOnly)
            }

            scrolling(config)
                .disabled(model.readOnly)
        }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .shortcut: ShortcutSheet(request: request) { apply(.keys($0), to: request.target) }
            case .command: CommandSheet(request: request) { apply(.run($0), to: request.target) }
            }
        }
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

    /// The named buttons the connected mice have (all when none has reported), plus any bound
    /// globally or in this app.
    private func namedRows(_ config: ConfigTree) -> [String] {
        let controls = model.devices.flatMap(\.controls)
        let deviceCIDs = controls.isEmpty ? nil : Set(controls.map(\.cid))
        let boundCIDs = Set(configKeys(config).compactMap(NamedButton.cid(forKey:)))
        return NamedButton.allCases.filter { button in
            deviceCIDs.map { $0.contains(button.cid) } ?? true || boundCIDs.contains(button.cid)
        }.map(\.rawValue)
    }

    private func otherRows(_ config: ConfigTree) -> [String] {
        ButtonRows.others(deviceCIDs: model.devices.flatMap(\.controls).map(\.cid), configKeys: configKeys(config))
    }

    private func configKeys(_ config: ConfigTree) -> [String] {
        [["buttons"], scope + ["buttons"]].flatMap { (config[$0] as? [String: Any]).map { Array($0.keys) } ?? [] }
    }

    private func title(_ button: String) -> String {
        NamedButton(rawValue: button)?.label ?? "Control \(button)"
    }

    /// What applies elsewhere, for "Same as Everywhere (…)".
    private func globalLabel(_ action: ButtonAction, direction: Bool = false) -> String {
        action == .standard ? (direction ? "Do Nothing" : "Default") : action.label
    }

    @ViewBuilder
    private func row(_ button: String, _ config: ConfigTree, indented: Bool = false) -> some View {
        let own = config.binding(button, in: scope)
        let global = config.binding(button)
        let target = BindingTarget(button: button, app: key)
        if own == .gesture {
            let isExpanded = Binding(get: { expanded.contains(button) },
                                     set: { if $0 { expanded.insert(button) } else { expanded.remove(button) } })
            LabeledContent {
                actionButton(own, target: target, sameAsEverywhere: globalLabel(global))
            } label: {
                DisclosureLabel(title: title(button), isExpanded: isExpanded)
            }
            .padding(.leading, indented ? 16 : 0)
            if isExpanded.wrappedValue {
                ForEach(Gesture.directions, id: \.self) { direction in
                    let mine = config.gestureBinding(button, direction, in: scope)
                    // A direction the app leaves out follows the global gesture, if there is one.
                    let inherited = global == .gesture
                        ? globalLabel(config.gestureBinding(button, direction), direction: true) : nil
                    LabeledContent(Gesture.label(direction)) {
                        actionButton(mine == .standard && inherited == nil ? .named("none") : mine,
                                     target: BindingTarget(button: button, direction: direction, app: key),
                                     sameAsEverywhere: inherited)
                    }
                    .padding(.leading, indented ? 38 : 22)
                }
            }
        } else {
            LabeledContent {
                actionButton(own, target: target, sameAsEverywhere: globalLabel(global))
            } label: {
                Text(title(button))
            }
            .padding(.leading, indented ? 16 : 0)
        }
    }

    private func actionButton(_ action: ButtonAction, target: BindingTarget, sameAsEverywhere: String?) -> some View {
        let id = target.direction.map { "\(target.button).\($0)" } ?? target.button
        let isDirection = target.direction != nil
        return ActionButton(
            action: action,
            allowsDefault: false,
            allowsGesture: !isDirection,
            isPresented: Binding(get: { presented == id }, set: { presented = $0 ? id : nil }),
            choose: { entry in choose(entry, for: target, current: action) },
            accessibilityName: target.title + spoken,
            sameAsEverywhere: sameAsEverywhere)
    }

    private func choose(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .set(let action): apply(action, to: target)
        case .gesture:
            apply(.gesture, to: target)
            expanded.insert(target.button)
        case .shortcut:
            let initial = if case .keys(let spec) = current { spec } else { "" }
            DispatchQueue.main.async { sheet = SheetRequest(kind: .shortcut, target: target, initial: initial) }
        case .command:
            let initial = if case .run(let command) = current { command } else { "" }
            DispatchQueue.main.async { sheet = SheetRequest(kind: .command, target: target, initial: initial) }
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
        let overrides = config.overridesScrolling(key)
        let smooth = config.scrollsSmoothly(key)
        let speedPath = scope + ["smoothScroll", "speed"]
        let glidePath = scope + ["smoothScroll", "smoothingMs"]
        let globalSpeed = config.double(["smoothScroll", "speed"]) ?? 1
        let globalGlide = config.double(["smoothScroll", "smoothingMs"]) ?? 125
        let help: String = if !overrides {
            "Off uses the speed and glide set in Scrolling."
        } else if !smooth {
            "Smooth scrolling is off, so this app scrolls at this speed without the glide."
        } else if !config.smoothScrollEnabled {
            "Smooth scrolling is on in this app only."
        } else {
            "Off uses the speed and glide set in Scrolling."
        }
        return Section("Scrolling") {
            Toggle(isOn: Binding(get: { overrides }, set: { on in model.update { $0.setOverridesScrolling(key, on) } })) {
                RowLabel("Own scrolling speed", help: help)
            }
            .accessibilityLabel("Own scrolling speed\(spoken)")
            Group {
                ValueSlider(title: "Speed", spokenTitle: "Scrolling speed\(spoken)",
                            value: overrides ? model.number(speedPath, default: globalSpeed, step: 0.05) : .constant(globalSpeed),
                            range: 0.25...3, low: "Slow", high: "Fast", format: Format.multiplier)
                ValueSlider(title: "Glide", spokenTitle: "Glide\(spoken)", help: "0 scrolls instantly.",
                            value: overrides ? model.number(glidePath, default: globalGlide, step: 25) : .constant(globalGlide),
                            range: 0...500, low: "Short", high: "Long", format: Format.milliseconds)
                    .disabled(!smooth)
            }
            .disclosedRow()
            .disabled(!overrides)
        }
    }
}
