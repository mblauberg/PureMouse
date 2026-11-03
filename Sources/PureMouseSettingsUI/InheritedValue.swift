import PureMouseAppSupport
import SwiftUI

/// The names of the scopes a setting may be left to, and how a row says it has its own value
/// (docs/ui-language.md, "A value left to a wider scope"): the one place the words live.
enum InheritedScope {
    static let everywhere = "Everywhere"
    static let allMice = "All Mice"

    /// "Same as Everywhere": a pop-up's first entry, which removes the own value.
    static func sameAs(_ source: String) -> String { "Same as \(source)" }

    /// "Use All Mice Setting": the action that removes a row's own value.
    static func use(_ source: String) -> String { "Use \(source) Setting" }

    /// Who the value belongs to: "this mouse" under All Mice, "this app" under Everywhere.
    static func owner(of source: String) -> String { source == allMice ? "this mouse" : "this app" }

    /// "Set for this mouse.": a changed row's caption.
    static func setFor(_ source: String) -> String { "Set for \(owner(of: source))." }
}

/// A setting one scope may leave to a wider one: an app to everywhere, a mouse to all mice. One
/// type for every such row (docs/ui-language.md, "A value left to a wider scope"); it marks
/// changes, not inheritance:
/// - left unset, the row looks as it does in the wider scope: the same control, full contrast,
///   its usual caption;
/// - set, its caption reads "Set for this mouse." ("Set for this app.") with a "Use All Mice
///   Setting" button that removes the own value (`InheritedOverride`), also in the row's context
///   menu and as a VoiceOver action; the row's usual caption moves to its tooltip.
/// A pop-up keeps "Same as <source> (<value>)" as its first entry.
struct InheritedValue<Value> {
    /// The scope's own value; nil when it leaves the setting to `source`.
    var own: Value?
    /// What applies when `own` is nil.
    var inherited: Value
    /// The wider scope, as the words name it: "Everywhere", "All Mice".
    var source: String

    var isInherited: Bool { own == nil }
    var effective: Value { own ?? inherited }
    /// The row's caption: "Set for this mouse." while the scope has its own value, else none.
    var caption: String? { isInherited ? nil : InheritedScope.setFor(source) }
    /// The pop-up entry that removes the own value, without the value it keeps.
    var entry: String { InheritedScope.sameAs(source) }
    /// The command that removes the own value.
    var resetTitle: String { InheritedScope.use(source) }

    /// What a row shows and offers while the scope has its own value; nil while it inherits.
    /// `reset` removes the own value.
    func note(reset: @escaping () -> Void) -> InheritedOverride? {
        isInherited ? nil : InheritedOverride(source: source, reset: reset)
    }
}

extension InheritedValue: Equatable where Value: Equatable {}
extension InheritedValue: Sendable where Value: Sendable {}

extension InheritedValue where Value == String {
    /// What VoiceOver reads as the control's value: "Mission Control, same as Everywhere".
    var spoken: String { isInherited ? "\(effective), same as \(source)" : effective }
}

/// A row whose scope has its own value: the caption "Set for this mouse." with its button, the
/// same command in the context menu and as a VoiceOver action, and the row's help as a tooltip
/// (`View.overridable(_:help:)`). Made by `InheritedValue.note(reset:)`.
struct InheritedOverride {
    let source: String
    /// Removes the own value.
    let reset: () -> Void

    var caption: String { InheritedScope.setFor(source) }
    var resetTitle: String { InheritedScope.use(source) }

    /// The tooltips are under 75 characters (docs/ui-language.md): `help` as far as whole
    /// sentences fit, else shortened in the middle.
    static func tooltip(for help: String?) -> String {
        guard let help = help?.trimmingCharacters(in: .whitespaces), !help.isEmpty else { return "" }
        guard help.count > ActionButton.tooltipLimit else { return help }
        var text = ""
        for sentence in help.split(separator: ". ", omittingEmptySubsequences: true) {
            let next = text.isEmpty ? String(sentence) : text + ". " + sentence
            let ended = next.hasSuffix(".") ? next : next + "."
            guard ended.count <= ActionButton.tooltipLimit else { break }
            text = ended
        }
        if !text.isEmpty { return text }
        let half = (ActionButton.tooltipLimit - 1) / 2
        return help.prefix(half) + "…" + help.suffix(ActionButton.tooltipLimit - 1 - half)
    }
}

/// Where a row stands against the wider scope: nothing wider (All Mice, Everywhere), left to it, or
/// the scope's own value. One answer for every control of a row: its caption and "Use … Setting"
/// link while own (`note`), and its spoken value while left to the wider scope (`spoken`), which
/// a native switch, segmented control or slider has no other way to say.
struct RowStanding {
    /// The wider scope the setting may be left to; nil when there is none.
    var source: String?
    /// The scope has its own value.
    var isOwn = false
    /// Removes the own value.
    var reset: () -> Void = {}

    /// All Mice and Everywhere: nothing to inherit.
    static var none: RowStanding { RowStanding(source: nil) }

    /// A mouse's row for the config `paths`: own while the mouse holds any of them. Any other scope
    /// has no wider one here.
    static func of(_ paths: [[String]], in config: ConfigTree, scope: ConfigScope, reset: @escaping () -> Void = {}) -> RowStanding {
        guard scope.deviceKey != nil else { return .none }
        return RowStanding(source: InheritedScope.allMice, isOwn: paths.contains { config.isOverridden($0, in: scope) }, reset: reset)
    }

    var isInherited: Bool { source != nil && !isOwn }

    /// What a row shows and offers while the scope has its own value.
    var note: InheritedOverride? {
        guard let source, isOwn else { return nil }
        return InheritedOverride(source: source, reset: reset)
    }

    /// `value` as VoiceOver reads a control left to the wider scope: "On, same as All Mice".
    func spoken(_ value: String) -> String {
        guard isInherited, let source else { return value }
        return "\(value), same as \(source)"
    }
}

/// The caption line of a changed row: "Set for this mouse." and, on the same line, the button that
/// gives the setting back. The button reads as a link, and VoiceOver says which row it is for
/// ("Use All Mice Setting for Speed"), since several rows of a pane may be changed at once.
struct OverrideLine: View {
    let note: InheritedOverride
    /// What VoiceOver calls the row the line belongs to.
    let subject: String

    /// What VoiceOver calls the button.
    static func spokenReset(_ note: InheritedOverride, subject: String) -> String { "\(note.resetTitle) for \(subject)" }

    var body: some View {
        HStack(spacing: 4) {
            Text(note.caption)
                .foregroundStyle(.secondary)
            // A line of caption text is under 20 pt tall; the padding takes the hit target to the
            // minimum (docs/ui-design.md), and the plain style keeps the label's own frame.
            Button { note.reset() } label: { Text(note.resetTitle).padding(.vertical, 3).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(Self.spokenReset(note, subject: subject))
                .accessibilityAddTraits(.isLink)
                .modifier(LinkPointer())
        }
        .font(.subheadline)
    }
}

extension View {
    /// A row of a setting a wider scope can supply. While `note` is set, the row's `help` is its
    /// tooltip (its caption is `OverrideLine`) and the command that removes the own value is in its
    /// context menu and a VoiceOver action. The modifiers stay on the row in either state, so
    /// the control keeps its identity as its value goes from inherited to own mid-drag.
    func overridable(_ note: InheritedOverride?, help: String?) -> some View {
        self
            .help(note == nil ? "" : InheritedOverride.tooltip(for: help))
            .contextMenu {
                if let note { Button(note.resetTitle) { note.reset() } }
            }
            .accessibilityActions {
                if let note { Button(note.resetTitle) { note.reset() } }
            }
    }
}

/// A pop-up for an `InheritedValue`: closed, it shows the value in effect; open, its first entry
/// is "Same as <source> (<value>)", which removes the own value. A `Picker` can't do this alone:
/// its closed pop-up shows the chosen entry's own text, so it would read "Same as Everywhere (…)"
/// instead of the value. So a `Menu` shows the value and holds an inline `Picker`, which keeps
/// the checkmarks.
struct InheritedPicker<Value: Hashable>: View {
    /// The accessibility label.
    let title: String
    let value: InheritedValue<Value>
    let options: [Value]
    let label: (Value) -> String
    /// nil removes the own value.
    let choose: (Value?) -> Void

    var body: some View {
        PopUpMenu(text: label(value.effective)) {
            Picker(title, selection: Binding(get: { value.own }, set: { choose($0) })) {
                Text("\(value.entry) (\(label(value.inherited)))").tag(nil as Value?)
                Divider()
                ForEach(options, id: \.self) { Text(label($0)).tag($0 as Value?) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel(title)
        .accessibilityValue(InheritedValue(own: value.own.map(label), inherited: label(value.inherited),
                                           source: value.source).spoken)
    }
}
