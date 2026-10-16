import AppKit
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

    /// The picker's entries, in order. Gesture directions get neither Default nor Hold and Move.
    /// In an app, `sameAsEverywhere` (what applies elsewhere) adds the entry that removes the
    /// app's own binding.
    static func all(allowsDefault: Bool, allowsGesture: Bool, sameAsEverywhere: String? = nil) -> [PickerEntry] {
        var entries: [PickerEntry] = []
        if let inherited = sameAsEverywhere {
            entries.append(PickerEntry(id: "inherit", label: "Same as Everywhere", detail: "(\(inherited))", group: nil,
                                       kind: .set(.standard), symbol: "globe"))
        }
        if allowsDefault {
            entries.append(PickerEntry(id: "default", label: "Default", detail: "(Works as Normal)", group: nil,
                                       kind: .set(.standard)))
        }
        entries.append(PickerEntry(id: "none", label: "Do Nothing", group: nil, kind: .set(.named("none")),
                                   symbol: ActionCatalog.symbol(for: "none")))
        for group in ActionCatalog.groups {
            for name in group.names {
                entries.append(PickerEntry(id: name, label: ActionCatalog.label(for: name), group: group.title,
                                           kind: .set(.named(name)), symbol: ActionCatalog.symbol(for: name)))
            }
        }
        for name in ActionCatalog.hapticNames {
            entries.append(PickerEntry(id: "haptic." + name, label: ActionCatalog.hapticLabel(for: name),
                                       group: ActionCatalog.hapticGroup, kind: .set(.haptic(name)), symbol: "waveform"))
        }
        entries.append(PickerEntry(id: "keys", label: "Keyboard Shortcut…", group: "Custom", kind: .shortcut,
                                   symbol: "keyboard"))
        entries.append(PickerEntry(id: "run", label: "Run Shell Command…", group: "Custom", kind: .command,
                                   symbol: "terminal"))
        if allowsGesture {
            entries.append(PickerEntry(id: "gesture", label: "Hold and Move", detail: "(Gestures)", group: "Custom",
                                       kind: .gesture, symbol: "arrow.up.and.down.and.arrow.left.and.right"))
        }
        return entries
    }

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

/// The popover behind each action button: a search field over a grouped list, operated with the
/// arrow keys and Return as well as the pointer.
struct ActionPicker: View {
    let current: ButtonAction
    let entries: [PickerEntry]
    /// Opened from the keyboard: the search field takes focus at once. Opened with the pointer,
    /// nothing is focused (no ring or caret) until the first keystroke, which goes to the search.
    var focusSearch = false
    let choose: (PickerEntry) -> Void

    @State private var query = ""
    @State private var highlighted: String?

    private var visible: [PickerEntry] { PickerEntry.filter(entries, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchField(text: $query, placeholder: "Search actions", focusOnAppear: focusSearch,
                        onMove: move, onSubmit: submit)
                .frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                            if entry.group != nil, index == 0 || visible[index - 1].group != entry.group {
                                Text(entry.group!)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 2 : 8)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            PickerRow(entry: entry, checked: entry.matches(current), highlighted: highlighted == entry.id)
                                .id(entry.id)
                                .onHover { if $0 { highlighted = entry.id } }
                                .onTapGesture { choose(entry) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { choose(entry) }
                        }
                        if visible.isEmpty {
                            Text("No matching actions").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .padding(8)
        .frame(width: 260)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { highlighted = entries.first { $0.matches(current) }?.id }
        .onChange(of: query) { _, _ in highlighted = visible.first?.id }
    }

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : list.count)
        highlighted = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func submit() {
        if let entry = visible.first(where: { $0.id == highlighted }) ?? visible.first { choose(entry) }
    }
}

private struct PickerRow: View {
    let entry: PickerEntry
    let checked: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .opacity(checked ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)
            Image(systemName: entry.symbol ?? "circle")
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .opacity(entry.symbol == nil ? 0 : 1)
                .accessibilityHidden(true)
            Text(entry.label)
            if let detail = entry.detail {
                Text(detail).foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
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

/// The pop-up-style button showing a binding; it opens the picker.
struct ActionButton: View {
    let action: ButtonAction
    let allowsDefault: Bool
    let allowsGesture: Bool
    var highlighted = false
    @Binding var isPresented: Bool
    let choose: (PickerEntry) -> Void
    var accessibilityName: String
    /// In an app: what applies elsewhere. `.standard` then reads "Same as Everywhere".
    var sameAsEverywhere: String?
    @State private var openedFromKeyboard = false

    private var label: String {
        action == .standard && sameAsEverywhere != nil ? "Same as Everywhere" : action.label
    }

    var body: some View {
        Button {
            openedFromKeyboard = NSApp.currentEvent?.type == .keyDown
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(action == .standard ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 168)
        }
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 3)
                    .padding(-2)
            }
        }
        .help(helpText)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(action == .standard && sameAsEverywhere == nil ? "Default" : label)
        .accessibilityHint("Opens the list of actions")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActionPicker(current: action,
                         entries: PickerEntry.all(allowsDefault: allowsDefault, allowsGesture: allowsGesture,
                                                  sameAsEverywhere: sameAsEverywhere),
                         focusSearch: openedFromKeyboard) { entry in
                isPresented = false
                choose(entry)
            }
        }
    }

    private var helpText: String {
        switch action {
        case .run(let command): "Runs: \(command)"
        case .keys(let spec): "Presses \(Shortcut.display(spec) ?? spec)"
        default: ""
        }
    }
}
