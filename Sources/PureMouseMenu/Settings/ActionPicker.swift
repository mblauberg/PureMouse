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

    /// The picker's entries, in order. Gesture directions get neither Default nor Hold and Move.
    static func all(allowsDefault: Bool, allowsGesture: Bool) -> [PickerEntry] {
        var entries: [PickerEntry] = []
        if allowsDefault {
            entries.append(PickerEntry(id: "default", label: "Default", detail: "(works as normal)", group: nil,
                                       kind: .set(.standard)))
        }
        entries.append(PickerEntry(id: "none", label: "Do Nothing", group: nil, kind: .set(.named("none"))))
        for group in ActionCatalog.groups {
            for name in group.names {
                entries.append(PickerEntry(id: name, label: ActionCatalog.label(for: name), group: group.title,
                                           kind: .set(.named(name))))
            }
        }
        entries.append(PickerEntry(id: "keys", label: "Keyboard Shortcut…", group: "Custom", kind: .shortcut))
        entries.append(PickerEntry(id: "run", label: "Run Shell Command…", group: "Custom", kind: .command))
        if allowsGesture {
            entries.append(PickerEntry(id: "gesture", label: "Hold and Move", detail: "(gestures)", group: "Custom",
                                       kind: .gesture))
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
    let choose: (PickerEntry) -> Void

    @State private var query = ""
    @State private var highlighted: String?

    private var visible: [PickerEntry] { PickerEntry.filter(entries, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchField(text: $query, placeholder: "Search actions", onMove: move, onSubmit: submit)
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

/// A native `NSSearchField` that hands ↑/↓/Return to the list below it and takes focus at once.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(parent: SearchField) { self.parent = parent }

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

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(action.label)
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
        .accessibilityValue(action == .standard ? "Default" : action.label)
        .accessibilityHint("Opens the list of actions")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActionPicker(current: action,
                         entries: PickerEntry.all(allowsDefault: allowsDefault, allowsGesture: allowsGesture)) { entry in
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
