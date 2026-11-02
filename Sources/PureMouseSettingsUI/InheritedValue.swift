import SwiftUI

/// The names of the scopes a setting may be left to, and how a row says it follows one
/// (docs/ui-language.md, "App scope"): the one place the words live.
enum InheritedScope {
    static let everywhere = "Everywhere"
    static let allMice = "All Mice"

    /// "Same as Everywhere": a row's caption and a picker's entry.
    static func sameAs(_ source: String) -> String { "Same as \(source)" }
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
