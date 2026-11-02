import PureMouseAppSupport
import SwiftUI

/// The names of the scopes a setting may be left to, and how a row says it follows one
/// (docs/ui-language.md, "App scope"): the one place the words live.
enum InheritedScope {
    static let everywhere = "Everywhere"
    static let allMice = "All Mice"

    /// "Same as Everywhere": a row's caption and a picker's entry.
    static func sameAs(_ source: String) -> String { "Same as \(source)" }

    /// "Use All Mice Setting": the action that removes a row's own value.
    static func use(_ source: String) -> String { "Use \(source) Setting" }
}

/// A setting one scope may leave to a wider one: an app to everywhere, a mouse to all mice. One
/// presentation for every such row (docs/ui-language.md, "A value left to a wider scope"):
/// - left unset, the row shows the value in effect in `.secondary`, with the caption "Same as
///   <source>" under its title;
/// - set, it shows its own value in primary text, with no caption.
/// Its picker keeps "Same as <source> (<value>)" as the entry that removes the own value.
struct InheritedValue<Value> {
    /// The scope's own value; nil when it leaves the setting to `source`.
    var own: Value?
    /// What applies when `own` is nil.
    var inherited: Value
    /// The wider scope, as the caption names it: "Everywhere", "All Mice".
    var source: String

    var isInherited: Bool { own == nil }
    var effective: Value { own ?? inherited }
    /// The row's caption: "Same as Everywhere" while inherited, else none.
    var caption: String? { isInherited ? InheritedScope.sameAs(source) : nil }
    /// The picker entry that removes the own value, without the value it keeps.
    var entry: String { InheritedScope.sameAs(source) }
    var style: HierarchicalShapeStyle { isInherited ? .secondary : .primary }
}

extension InheritedValue: Equatable where Value: Equatable {}
extension InheritedValue: Sendable where Value: Sendable {}

extension InheritedValue where Value == String {
    /// What VoiceOver reads as the control's value: "Mission Control, same as Everywhere".
    var spoken: String { isInherited ? "\(effective), same as \(source)" : effective }
}

/// A pop-up for an `InheritedValue`: closed, it shows the value in effect, dimmed while inherited;
/// open, its first entry is "Same as <source> (<value>)", which removes the own value. A `Picker`
/// can't do this alone: its closed pop-up shows the chosen entry's own text, so it would read
/// "Same as Everywhere (…)" instead of the value. So a `Menu` shows the value and holds an inline
/// `Picker`, which keeps the checkmarks.
struct InheritedPicker<Value: Hashable>: View {
    /// The accessibility label.
    let title: String
    let value: InheritedValue<Value>
    let options: [Value]
    let label: (Value) -> String
    /// nil removes the own value.
    let choose: (Value?) -> Void

    var body: some View {
        PopUpMenu(text: label(value.effective), style: value.style) {
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

/// The inheritance of a row that is not a pop-up (a slider, the Presets row): its words and dimming
/// come from the same `InheritedValue` as every other, and `reset` removes the own value, "Use All
/// Mice Setting" (`InheritedReset`).
struct InheritedRow {
    let source: String
    let isOverridden: Bool
    let reset: () -> Void

    private var value: InheritedValue<Bool> { InheritedValue(own: isOverridden ? true : nil, inherited: false, source: source) }
    var caption: String? { value.caption }
    var style: HierarchicalShapeStyle { value.style }
    var resetTitle: String { InheritedScope.use(source) }
}

/// The button at the trailing edge of a row that has its own value: it gives the setting back to
/// the wider scope. It keeps its place, hidden, while the row inherits, so the row does not shift.
struct InheritedReset: View {
    let row: InheritedRow

    var body: some View {
        Button { row.reset() } label: {
            // A circled symbol at title3 with this padding makes a 21 pt target, as in the presets sheet.
            Image(systemName: "arrow.uturn.backward.circle").font(.title3).padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(row.resetTitle)
        .accessibilityLabel(row.resetTitle)
        .opacity(row.isOverridden ? 1 : 0)
        .disabled(!row.isOverridden)
        .accessibilityHidden(!row.isOverridden)
    }
}

/// A row with a pop-up for a setting a mouse may leave to All Mice (`InheritedPicker`): its caption
/// says "Same as All Mice" while it does, in place of the help line.
struct InheritedChoiceRow<Value: Hashable>: View {
    let title: String
    var help: String?
    /// What VoiceOver calls the pop-up where the title alone is ambiguous.
    var spokenTitle: String?
    let value: InheritedValue<Value>
    let options: [Value]
    let text: (Value) -> String
    var availability = ControlAvailability.available
    let choose: (Value?) -> Void

    var body: some View {
        LabeledContent {
            InheritedPicker(title: spokenTitle ?? title, value: value, options: options, label: text, choose: choose)
        } label: {
            RowLabel(title, help: value.caption ?? help, availability: availability)
        }
    }
}
