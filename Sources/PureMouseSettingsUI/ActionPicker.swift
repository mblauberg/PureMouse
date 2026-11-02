import AppKit
import PureMouseAppSupport
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

    /// The picker's entries, in order. Gesture directions get neither Mouse Default nor Hold and
    /// Move. In an app, `sameAsEverywhere` (what applies elsewhere) adds the entry that removes the
    /// app's own binding. `haptics`: whether to list the haptic waveforms (`ControlAvailability`).
    static func all(allowsDefault: Bool, allowsGesture: Bool, sameAsEverywhere: String? = nil,
                    haptics: Bool = true) -> [PickerEntry] {
        var entries: [PickerEntry] = []
        if let inherited = sameAsEverywhere {
            entries.append(PickerEntry(id: "inherit", label: "Same as Everywhere", detail: "(\(inherited))", group: nil,
                                       kind: .set(.standard), symbol: "globe"))
        }
        if allowsDefault {
            entries.append(PickerEntry(id: "default", label: ButtonAction.standard.label, group: nil, kind: .set(.standard)))
        }
        entries.append(PickerEntry(id: "none", label: "Do Nothing", group: nil, kind: .set(.named("none")),
                                   symbol: ActionCatalog.symbol(for: "none")))
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

    var isHaptic: Bool { group == ActionCatalog.hapticGroup }

    func matches(_ action: ButtonAction) -> Bool {
        switch (kind, action) {
        case (.set(let mine), _): mine == action
        case (.shortcut, .keys), (.command, .run), (.gesture, .gesture): true
        default: false
        }
    }

    static func filter(_ entries: [PickerEntry], query: String) -> [PickerEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.label.localizedStandardContains(query) || ($0.group?.localizedStandardContains(query) ?? false)
        }
    }
}

/// A row of the picker's list: an entry, or the haptic group's own row, which opens and closes
/// the group (collapsed by default, since only one mouse has the motor).
enum PickerItem: Identifiable, Equatable {
    case entry(PickerEntry)
    case hapticGroup(expanded: Bool)

    static let hapticGroupID = "group.haptics"
    static let hapticCaption = "Makes the mouse vibrate. Needs an MX Master 4."

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .hapticGroup: Self.hapticGroupID
        }
    }

    /// The section the row sits under: the haptic group's entries sit under its row, not a header.
    var section: String? {
        switch self {
        case .entry(let entry): entry.isHaptic ? nil : entry.group
        case .hapticGroup: nil
        }
    }

    /// The rows for a search: the haptic entries fold into their group's row, which is open while
    /// `hapticsOpen` or while the search matches one of them.
    static func visible(_ entries: [PickerEntry], query: String, hapticsOpen: Bool) -> [PickerItem] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let expanded = hapticsOpen || searching
        var items: [PickerItem] = []
        for entry in PickerEntry.filter(entries, query: query) {
            if entry.isHaptic {
                if !items.contains(.hapticGroup(expanded: expanded)) { items.append(.hapticGroup(expanded: expanded)) }
                if expanded { items.append(.entry(entry)) }
            } else {
                items.append(.entry(entry))
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
    /// Opened from the keyboard: the search field takes focus at once. Opened with the pointer,
    /// nothing is focused (no ring or caret) until the first keystroke, which goes to the search.
    var focusSearch = false
    let choose: (PickerEntry) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var hapticsOpen: Bool

    init(current: ButtonAction, entries: [PickerEntry], focusSearch: Bool = false, choose: @escaping (PickerEntry) -> Void) {
        self.current = current
        self.entries = entries
        self.focusSearch = focusSearch
        self.choose = choose
        _hapticsOpen = State(initialValue: PickerItem.opensHaptics(for: current))
    }

    private var visible: [PickerItem] { PickerItem.visible(entries, query: query, hapticsOpen: hapticsOpen) }

    /// Consecutive rows under one header.
    private var sections: [(title: String?, items: [PickerItem])] {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchField(text: $query, placeholder: "Search actions", focusOnAppear: focusSearch,
                        onMove: move, onSubmit: submit)
                .frame(height: 22)
            ScrollViewReader { proxy in
                List(selection: Binding(get: { highlighted }, set: select)) {
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
            .frame(idealHeight: 420)
        }
        .padding(8)
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
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
        }
    }

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : list.count)
        highlighted = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func submit() {
        if let item = visible.first(where: { $0.id == highlighted }) ?? visible.first { activate(item) }
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
        }
        .padding(.leading, entry.isHaptic ? 12 : 0)
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
/// trailing, the system chevrons; a value left unset in secondary). It opens the searchable
/// picker, which a `Picker` cannot hold.
struct ActionButton: View {
    @Environment(AppModel.self) private var model
    let action: ButtonAction
    let allowsDefault: Bool
    let allowsGesture: Bool
    @Binding var isPresented: Bool
    let choose: (PickerEntry) -> Void
    var accessibilityName: String
    /// In an app: what applies elsewhere. `.standard` then reads "Same as Everywhere".
    var sameAsEverywhere: String?
    @State private var openedFromKeyboard = false

    /// Longer labels (a command) are shortened in the middle to this many characters.
    static let labelLimit = 32

    private var label: String {
        action == .standard && sameAsEverywhere != nil ? "Same as Everywhere" : action.label
    }

    /// The haptic waveforms, unless the mouse is known to have no motor; a bound one still shows.
    private var offersHaptics: Bool {
        let bound = if case .haptic = action { true } else { false }
        return ControlAvailability.of([\.haptics], devices: model.capabilityDevices, configured: bound).isShown
    }

    var body: some View {
        Button {
            openedFromKeyboard = NSApp.currentEvent?.type == .keyDown
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(Self.shortened(label))
                    .lineLimit(1)
                    .foregroundStyle(action == .standard ? .secondary : .primary)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(label)
        .accessibilityHint("Opens the list of actions")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActionPicker(current: action,
                         entries: PickerEntry.all(allowsDefault: allowsDefault, allowsGesture: allowsGesture,
                                                  sameAsEverywhere: sameAsEverywhere, haptics: offersHaptics),
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

    private var helpText: String {
        switch action {
        case .run(let command): "Runs: \(command)"
        case .keys(let spec): "Presses \(Shortcut.display(spec) ?? spec)"
        default: ""
        }
    }
}
