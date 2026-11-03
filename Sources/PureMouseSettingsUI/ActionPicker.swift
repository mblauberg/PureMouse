import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// One choice in the action picker.
struct PickerEntry: Identifiable, Equatable {
    enum Kind: Equatable { case set(ButtonAction), shortcut, command, gesture }

    let id: String
    let label: String
    var detail: String?
    let group: String?
    let kind: Kind
    /// An SF Symbol shown before the label.
    var symbol: String?
    var shortcutText: String?
    var helpText: String?
    var appName: String?
    var category: String?
    var keywords: [String]?
    var shortcutWords: String?
    var isPackAction: Bool = false

    /// The picker's entries, in order. Gesture directions get neither Mouse Default nor Hold and
    /// Move. On a mouse or in an app, `inherited` (what applies elsewhere, and where from) adds the
    /// entry that removes the own binding, worded by its source, and Mouse Default then writes
    /// `"default"` as the scope's own value; but not while the wider scope already is Mouse Default
    /// (that is "Same as …" then), unless it is `current`. `haptics`: whether to list the haptic
    /// waveforms (`ControlAvailability`).
    static func all(allowsDefault: Bool, allowsGesture: Bool, inherited: InheritedValue<String>? = nil,
                    haptics: Bool = true, current: ButtonAction = .standard, app: String? = nil) -> [PickerEntry] {
        var entries: [PickerEntry] = []
        if let inherited {
            entries.append(PickerEntry(id: "inherit", label: inherited.entry, detail: "(\(inherited.inherited))", group: nil,
                                       kind: .set(.standard), symbol: "globe"))
        }
        let widerIsDefault = inherited?.inherited == ButtonAction.standard.label
        if allowsDefault, !widerIsDefault || current == .mouseDefault {
            // Where something wider applies, Mouse Default is a value of its own ("default") and
            // "Same as …" above is the entry that removes the key; at the top level they are one.
            entries.append(PickerEntry(id: "default", label: ButtonAction.standard.label, group: nil,
                                       kind: .set(inherited == nil ? .standard : .mouseDefault)))
        }
        entries.append(PickerEntry(id: "none", label: "Do Nothing", group: nil, kind: .set(.named("none")),
                                   symbol: ActionCatalog.symbol(for: "none")))

        // App-first: on an app's page, that app's actions follow the top three entries
        if let app, let pack = ActionPackCatalog.shared.pack(for: app) {
            for action in pack.actions {
                let shortcutText = Shortcut.display(action.payload)
                let spoken = Shortcut.spoken(action.payload)
                let shortcutWords = spoken + " " + action.payload.replacingOccurrences(of: "+", with: " ")
                let groupTitle = "\(pack.name)'s Actions: \(action.category)"
                entries.append(PickerEntry(
                    id: action.id,
                    label: action.label,
                    detail: nil,
                    group: groupTitle,
                    kind: .set(action.buttonAction),
                    symbol: packSymbol(for: action),
                    shortcutText: shortcutText,
                    helpText: action.keymapNote,
                    appName: pack.name,
                    category: action.category,
                    keywords: action.keywords,
                    shortcutWords: shortcutWords,
                    isPackAction: true
                ))
            }
        }

        for group in ActionCatalog.groups {
            for name in group.names {
                entries.append(PickerEntry(id: name, label: ActionCatalog.label(for: name), group: group.title,
                                           kind: .set(.named(name)), symbol: ActionCatalog.symbol(for: name)))
            }
        }
        if haptics {
            for name in ActionCatalog.hapticNames {
                entries.append(PickerEntry(id: "haptic." + name, label: ActionCatalog.hapticLabel(for: name),
                                           group: ActionCatalog.hapticGroup, kind: .set(.haptic(name)), symbol: "waveform"))
            }
        }
        entries.append(PickerEntry(id: "keys", label: "Keyboard Shortcut…", group: "Custom", kind: .shortcut,
                                   symbol: "keyboard"))
        entries.append(PickerEntry(id: "run", label: "Run Command…", group: "Custom", kind: .command,
                                   symbol: "terminal"))
        if allowsGesture {
            entries.append(PickerEntry(id: "gesture", label: ButtonAction.gesture.label, group: "Custom",
                                       kind: .gesture, symbol: "arrow.up.and.down.and.arrow.left.and.right"))
        }
        return entries
    }

    private static func packSymbol(for action: ActionPackEntry) -> String {
        switch action.category {
        case "Meeting":
            if action.id.contains("Audio") || action.id.contains("Microphone") || action.id.contains("mute") {
                return "mic"
            }
            if action.id.contains("video") || action.id.contains("Camera") {
                return "video"
            }
            if action.id.contains("Hand") {
                return "hand.raised"
            }
            if action.id.contains("Share") {
                return "display"
            }
            if action.id.contains("Chat") {
                return "bubble.left"
            }
            if action.id.contains("participants") {
                return "person.2"
            }
            return "video"
        case "Tools":
            return action.id.contains("Brush") ? "paintbrush" : "wrench"
        case "Editing", "Edit":
            return action.id.contains("blade") ? "scissors" : "pencil"
        case "View", "Slide Show":
            return "eye"
        case "Tabs":
            return "square.on.square"
        case "Navigation":
            return "arrow.right"
        case "Formatting", "Alignment":
            return "text.alignleft"
        case "Insert":
            return "plus.circle"
        case "Folding":
            return "chevron.up.chevron.down"
        default:
            return "app"
        }
    }

    var isHaptic: Bool { group == ActionCatalog.hapticGroup }

    /// Whether a mouse or an app may choose Mouse Default for the button `key`: only where the mouse
    /// has a behaviour of its own to hand back (`Config.nativeBehaviour(of:)`). Under All Mice the
    /// choice is just an unbound button, so it is always there; `current` keeps a hand-edited
    /// "default" on another control in view.
    static func offersMouseDefault(for key: String, inMouseOrApp: Bool, current: ButtonAction = .standard) -> Bool {
        guard inMouseOrApp else { return true }
        if current == .mouseDefault { return true }
        return NamedButton.cid(forKey: key).flatMap(Config.nativeBehaviour(of:)) != nil
    }

    func matches(_ action: ButtonAction) -> Bool {
        switch (kind, action) {
        case (.set(let mine), _): mine == action
        case (.shortcut, .keys), (.command, .run), (.gesture, .gesture): true
        default: false
        }
    }

    /// The search as typed, without its surrounding spaces; empty means no search.
    static func searchTerm(_ query: String) -> String { query.trimmingCharacters(in: .whitespaces) }

    func matchesQuery(_ query: String) -> Bool {
        let q = Self.searchTerm(query)
        guard !q.isEmpty else { return true }
        if label.localizedStandardContains(q) { return true }
        if let group, group.localizedStandardContains(q) { return true }
        if let category, category.localizedStandardContains(q) { return true }
        if let appName, appName.localizedStandardContains(q) { return true }
        if let keywords, keywords.contains(where: { $0.localizedStandardContains(q) || q.localizedStandardContains($0) }) { return true }
        if let shortcutWords, shortcutWords.localizedStandardContains(q) { return true }
        if let shortcutText, shortcutText.localizedStandardContains(q) { return true }
        return false
    }

    static func filter(_ entries: [PickerEntry], query: String) -> [PickerEntry] {
        let q = searchTerm(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.matchesQuery(q) }
    }
}

/// A row of the picker's list: an entry, or the haptic group's own row, which opens and closes
/// the group (collapsed by default, since only one mouse has the motor).
enum PickerItem: Identifiable, Equatable {
    case entry(PickerEntry)
    case hapticGroup(expanded: Bool)
    case showAll(section: String, count: Int)
    case packHint(String)

    static let hapticGroupID = "group.haptics"
    static let hapticCaption = "Makes the mouse vibrate. Needs an MX Master 4."

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .hapticGroup: Self.hapticGroupID
        case .showAll(let section, _): "showAll.\(section)"
        case .packHint: "hint.pack"
        }
    }

    /// The section the row sits under: the haptic group's entries sit under its row, not a header.
    var section: String? {
        switch self {
        case .entry(let entry): entry.isHaptic ? nil : entry.group
        case .hapticGroup: nil
        case .showAll(let section, _): section
        case .packHint: nil
        }
    }

    /// The rows for a search or browse: sections over six rows fold to five plus Show All (N);
    /// search ignores folding; in Mouse scope, pack-only matches show the hint.
    static func visible(
        _ entries: [PickerEntry],
        query: String,
        hapticsOpen: Bool,
        expandedSections: Set<String> = [],
        app: String? = nil
    ) -> [PickerItem] {
        let queryTerm = PickerEntry.searchTerm(query)
        let searching = !queryTerm.isEmpty

        if searching {
            let filtered = entries.filter { $0.matchesQuery(queryTerm) }
            let sorted = filtered.sorted { a, b in
                if a.isPackAction != b.isPackAction {
                    return a.isPackAction && !b.isPackAction
                }
                return false
            }
            var items: [PickerItem] = sorted.map { entry in
                var e = entry
                if let cat = entry.category {
                    e.detail = cat
                }
                return .entry(e)
            }
            if app == nil && items.isEmpty {
                let matchingApps = ActionPackCatalog.shared.appsMatchingSearch(queryTerm)
                if !matchingApps.isEmpty {
                    let phrase: String
                    if matchingApps.count == 1 {
                        phrase = matchingApps[0]
                    } else if matchingApps.count == 2 {
                        phrase = "\(matchingApps[0]) and \(matchingApps[1])"
                    } else {
                        let prefix = matchingApps.dropLast().joined(separator: ", ")
                        phrase = "\(prefix) and \(matchingApps.last!)"
                    }
                    items.append(.packHint("Also in \(phrase). Choose them on the app's page."))
                }
            }
            return items
        }

        var items: [PickerItem] = []
        let expanded = hapticsOpen
        var grouped: [(title: String?, entries: [PickerEntry])] = []

        for entry in entries {
            if entry.isHaptic { continue }
            if let last = grouped.last, last.title == entry.group {
                grouped[grouped.count - 1].entries.append(entry)
            } else {
                grouped.append((entry.group, [entry]))
            }
        }

        for group in grouped {
            let sectionName = group.title ?? ""
            let count = group.entries.count
            let isCustom = sectionName == "Custom"
            let threshold = isCustom ? 5 : 6
            let isFolded = count > threshold && !expandedSections.contains(sectionName)

            if isFolded {
                for entry in group.entries.prefix(5) {
                    items.append(.entry(entry))
                }
                items.append(.showAll(section: sectionName, count: count))
            } else {
                for entry in group.entries {
                    items.append(.entry(entry))
                }
            }
        }

        let hapticEntries = entries.filter(\.isHaptic)
        if !hapticEntries.isEmpty {
            items.append(.hapticGroup(expanded: expanded))
            if expanded {
                for entry in hapticEntries {
                    items.append(.entry(entry))
                }
            }
        }

        return items
    }

    /// The group starts open when the current action is one of its waveforms.
    static func opensHaptics(for current: ButtonAction) -> Bool {
        if case .haptic = current { return true }
        return false
    }
}

/// The popover behind each action button: a search field over a grouped list, operated with the
/// arrow keys and Return as well as the pointer. The list draws the system's selection.
struct ActionPicker: View {
    let current: ButtonAction
    let entries: [PickerEntry]
    var app: String? = nil
    /// Opened from the keyboard: the search field takes focus at once. Opened with the pointer,
    /// nothing is focused (no ring or caret) until the first keystroke, which goes to the search.
    var focusSearch = false
    let choose: (PickerEntry) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var hapticsOpen: Bool
    @State private var expandedSections: Set<String> = []

    init(current: ButtonAction, entries: [PickerEntry], app: String? = nil, focusSearch: Bool = false, choose: @escaping (PickerEntry) -> Void) {
        self.current = current
        self.entries = entries
        self.app = app
        self.focusSearch = focusSearch
        self.choose = choose
        _hapticsOpen = State(initialValue: PickerItem.opensHaptics(for: current))
    }

    private var visible: [PickerItem] {
        PickerItem.visible(entries, query: query, hapticsOpen: hapticsOpen, expandedSections: expandedSections, app: app)
    }

    /// Consecutive rows under one header. Search results are flat.
    private var sections: [(title: String?, items: [PickerItem])] {
        if !PickerEntry.searchTerm(query).isEmpty {
            return [(nil, visible)]
        }
        var sections: [(title: String?, items: [PickerItem])] = []
        for item in visible {
            if let last = sections.last, last.title == item.section {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((item.section, [item]))
            }
        }
        return sections
    }

    nonisolated static func matchesPackAction(_ action: ActionPackEntry, query: String, appName: String) -> Bool {
        ActionPackCatalog.matches(action: action, query: query, appName: appName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchField(text: $query, placeholder: "Search actions", focusOnAppear: focusSearch,
                        onMove: move, onSubmit: submit)
                .accessibilityLabel("Search actions")
            ScrollViewReader { proxy in
                List(selection: Binding(get: { highlighted }, set: { select($0) })) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(section.items) { item in
                                row(item)
                                    .tag(item.id)
                                    .id(item.id)
                                    .accessibilityAction { activate(item) }
                            }
                        } header: {
                            if let title = section.title { Text(title) }
                        }
                    }
                    if visible.isEmpty {
                        Text("No matching actions").foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
                .onKeyPress(.return) {
                    submit()
                    return .handled
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .padding(8)
        // A List has no size of its own, so the popover keeps one width and height (allow-listed in
        // UIChromeScanTests); the search field and the list take theirs from the system.
        .frame(width: 260, height: 464)
        .onAppear { highlighted = entries.first { $0.matches(current) }?.id }
        .onChange(of: query) { _, _ in highlighted = visible.first?.id }
    }

    @ViewBuilder private func row(_ item: PickerItem) -> some View {
        switch item {
        case .entry(let entry):
            PickerRow(entry: entry, checked: entry.matches(current))
        case .hapticGroup(let expanded):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActionCatalog.hapticGroup)
                    if expanded {
                        Text(PickerItem.hapticCaption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        case .showAll(let section, let count):
            Button {
                expandedSections.insert(section)
            } label: {
                HStack {
                    Text("Show All (\(count))")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all \(count) actions in \(section)")
        case .packHint(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    /// The list sets the selection on a click, which picks the row as a menu does; anything
    /// else (arrows in a focused list) only moves the selection.
    private func select(_ id: String?) {
        highlighted = id
        guard let id, let item = visible.first(where: { $0.id == id }),
              let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return }
        activate(item)
    }

    private func activate(_ item: PickerItem) {
        switch item {
        case .entry(let entry): choose(entry)
        case .hapticGroup: hapticsOpen.toggle()
        case .showAll(let section, _): expandedSections.insert(section)
        case .packHint: break
        }
    }

    private func move(_ delta: Int) {
        let list = visible.filter {
            if case .packHint = $0 { return false }
            return true
        }
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : list.count)
        highlighted = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func submit() {
        let selectable = visible.filter {
            if case .packHint = $0 { return false }
            return true
        }
        if let item = selectable.first(where: { $0.id == highlighted }) ?? selectable.first {
            activate(item)
        }
    }
}

private struct PickerRow: View {
    let entry: PickerEntry
    let checked: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .opacity(checked ? 1 : 0)
                .accessibilityHidden(true)
            Label {
                HStack(spacing: 4) {
                    Text(entry.label)
                    if let detail = entry.detail { Text(detail).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: entry.symbol ?? "circle")
                    .opacity(entry.symbol == nil ? 0 : 1)
            }
            if let shortcut = entry.shortcutText {
                Spacer(minLength: 8)
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, entry.isHaptic ? 12 : 0)
        .help(entry.helpText ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A native `NSSearchField` that hands ↑/↓/Return to the list below it. Unless told to focus at
/// once, it takes focus on the first keystroke in its window, which it then receives.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var focusOnAppear = false
    let onMove: (Int) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        let focus = focusOnAppear
        DispatchQueue.main.async { field.window?.makeFirstResponder(focus ? field : nil) }
        context.coordinator.watchKeys(for: field)
        return field
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        private var monitor: Any?
        init(parent: SearchField) { self.parent = parent }

        /// Hands a keystroke to the field when nothing in its window has focus: it becomes first
        /// responder before the event is dispatched, so the key lands in it. Escape (close) and
        /// Tab (keyboard navigation) keep their usual meaning.
        func watchKeys(for field: NSSearchField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                nonisolated(unsafe) var result: NSEvent? = event
                MainActor.assumeIsolated {
                    guard let field, let window = field.window, field.currentEditor() == nil,
                          event.window === window || event.window === window.parent,
                          ![48, 53].contains(event.keyCode),
                          event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
                    // With nothing focused the popover may not be key; the key then reached
                    // the Settings window, so deliver it to the field here.
                    if !window.isKeyWindow { window.makeKey() }
                    window.makeFirstResponder(field)
                    if event.window !== window {
                        field.currentEditor()?.keyDown(with: event)
                        result = nil
                    }
                }
                return result
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            default: return false
            }
            return true
        }
    }
}

/// The button showing a binding, drawn as the form's own pop-up menus are (natural width,
/// trailing, the system chevrons; every choice in primary, an inherited one too). It opens the searchable
/// picker, which a `Picker` cannot hold.
struct ActionButton: View {
    @Environment(AppModel.self) private var model
    let action: ButtonAction
    let allowsDefault: Bool
    let allowsGesture: Bool
    @Binding var isPresented: Bool
    let choose: (PickerEntry) -> Void
    var accessibilityName: String
    /// In an app or on a mouse: what applies elsewhere, which `.standard` shows (`InheritedValue`).
    var sameAsInherited: String?
    /// `sameAsInherited` as VoiceOver says it (a shortcut in words); the label itself when nil.
    var spokenInherited: String?
    /// The wider scope `sameAsInherited` comes from: Mouse Settings for an app, All Mice for a mouse.
    var source = InheritedScope.mouseSettings
    /// The scope whose mice decide whether the haptic waveforms are listed.
    var scope = ConfigScope.global
    /// The bundle ID of the app whose pack actions apply.
    var app: String? = nil
    @State private var openedFromKeyboard = false

    /// A scope's binding as its row shows it: `.standard` leaves it to the inherited label.
    static func inherited(_ action: ButtonAction, inheriting: String, source: String = InheritedScope.mouseSettings) -> InheritedValue<String> {
        InheritedValue(own: action == .standard ? nil : action.label, inherited: inheriting, source: source)
    }

    /// A gesture direction as its row shows it: the scope's own, else the wider gesture's (or nothing).
    static func inherited(_ direction: AppButton.Direction, source: String) -> InheritedValue<String> {
        inherited(direction.own, inheriting: direction.inheritedLabel, source: source)
    }

    private var inherited: InheritedValue<String>? { sameAsInherited.map { Self.inherited(action, inheriting: $0, source: source) } }

    /// Longer labels (a command) are shortened in the middle to this many characters.
    static let labelLimit = 32

    private var label: String {
        if let inherited, inherited.isInherited { return inherited.effective }
        return Self.displayName(for: action, in: app)
    }

    /// Display name order for a stored binding: its label if it has one, else a match against the app's catalogue.
    public static func displayName(for action: ButtonAction, in app: String? = nil) -> String {
        if let app, let packAction = ActionPackCatalog.shared.action(matching: action, in: app) {
            return packAction.label
        }
        return action.label
    }

    /// What VoiceOver reads as the value: a shortcut in words ("Shift Command 4"), not glyphs, and
    /// an inherited one with its source ("Mission Control, same as Mouse Settings").
    static func spokenValue(for action: ButtonAction, in app: String? = nil, inheriting: String?, spokenInheriting: String?,
                            source: String = InheritedScope.mouseSettings) -> String {
        let ownSpoken: String? = if action == .standard {
            nil
        } else if let app, let packAction = ActionPackCatalog.shared.action(matching: action, in: app) {
            packAction.label
        } else {
            action.spokenLabel
        }
        guard let inheriting else { return ownSpoken ?? action.spokenLabel }
        return InheritedValue(own: ownSpoken, inherited: spokenInheriting ?? inheriting, source: source).spoken
    }

    static func spokenValue(for action: ButtonAction, inheriting: String?, spokenInheriting: String?,
                            source: String = InheritedScope.mouseSettings) -> String {
        spokenValue(for: action, in: nil, inheriting: inheriting, spokenInheriting: spokenInheriting, source: source)
    }

    /// The haptic waveforms, unless the mouse is known to have no motor; a bound one still shows.
    private var offersHaptics: Bool { Self.offersHaptics(for: action, devices: model.capabilityDevices(in: scope)) }

    /// Whether the picker lists the haptic waveforms for `devices` (`AppModel.capabilityDevices(in:)`):
    /// unless one is known to lack the motor, or when `action` is a waveform already bound.
    static func offersHaptics(for action: ButtonAction, devices: [Status.Device]) -> Bool {
        let bound = if case .haptic = action { true } else { false }
        return ControlAvailability.of([\.haptics], devices: devices, configured: bound).isShown
    }

    var body: some View {
        Button {
            openedFromKeyboard = NSApp.currentEvent?.type == .keyDown
            isPresented = true
        } label: {
            PopUpLabel(text: Self.shortened(label))
        }
        .fixedSize()
        .help(Self.tooltip(for: action, in: app))
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Self.spokenValue(for: action, in: app, inheriting: sameAsInherited, spokenInheriting: spokenInherited, source: source))
        .accessibilityHint("Opens the list of actions")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActionPicker(current: action,
                         entries: PickerEntry.all(allowsDefault: allowsDefault, allowsGesture: allowsGesture,
                                                  inherited: inherited, haptics: offersHaptics, current: action, app: app),
                         app: app,
                         focusSearch: openedFromKeyboard) { entry in
                isPresented = false
                choose(entry)
            }
        }
    }

    /// `text`, shortened in the middle to `labelLimit` characters.
    static func shortened(_ text: String) -> String {
        guard text.count > labelLimit else { return text }
        let half = (labelLimit - 1) / 2
        return text.prefix(half) + "…" + text.suffix(labelLimit - 1 - half)
    }

    /// The tooltips are under 75 characters (docs/ui-language.md).
    nonisolated static let tooltipLimit = 74

    /// The tooltip: what a shortcut presses or a command runs, shortened to `tooltipLimit`.
    static func tooltip(for action: ButtonAction, in app: String? = nil) -> String {
        if let app, let packAction = ActionPackCatalog.shared.action(matching: action, in: app),
           let note = packAction.keymapNote {
            return note
        }
        let text = switch action {
        case .run(let command): "Runs: \(command)"
        case .keys(let spec): "Presses \(Shortcut.display(spec) ?? spec)"
        default: ""
        }
        guard text.count > tooltipLimit else { return text }
        let half = (tooltipLimit - 1) / 2
        return text.prefix(half) + "…" + text.suffix(tooltipLimit - 1 - half)
    }

    static func tooltip(for action: ButtonAction) -> String {
        tooltip(for: action, in: nil)
    }
}
