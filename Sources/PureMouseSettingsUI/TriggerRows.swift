import PureMouseAppSupport
import SwiftUI

/// A button's rows on Mouse › Buttons (All Mice or one mouse) and on an app's Buttons (#158, ADR 24).
/// The pop-up always holds the click. Double-click and Hold are child rows under one disclosure
/// triangle, there only once wanted (More Ways to Press, at the foot of the click's picker) or once
/// they do something; Hold and Move's directions sit under its Hold row. Collapsed, the row's
/// caption sums them up; expanded, the rows replace it.
struct TriggerRows: View {
    let key: String
    let state: AppButton
    /// Where an inherited value comes from (All Mice for a mouse, Mouse Settings for an app); nil at
    /// the top level, which inherits nothing.
    let source: String?
    /// The row's own help (Other controls name the mice that have them).
    var help: String?
    /// Added to every pop-up's accessibility name: the mouse (", MX Master 3S") or app (" in Safari").
    var spokenSuffix = ""
    var indented = false
    var mark = RowMark.none
    /// Mouse Default is offered on the click (`PickerEntry.offersMouseDefault`).
    let offersMouseDefault: Bool
    /// The live double-click interval, for the Double-click row's caption.
    let doubleClickMs: Int
    var scope = ConfigScope.global
    /// Rows whose children show, by button key.
    @Binding var expanded: Set<String>
    /// Child rows added from More Ways to Press that do nothing yet, as "button.trigger".
    @Binding var wanted: Set<String>
    /// The pop-up whose picker is open: a button key, or "button.trigger".
    @Binding var presented: String?
    /// A choice to write or to edit in a sheet; `target.direction` names the trigger (nil: the click).
    let choose: (PickerEntry, BindingTarget, ButtonAction) -> Void
    /// The picker of `target` opened.
    var opened: (BindingTarget) -> Void = { _ in }

    private var title: String { NamedButton.title(forKey: key) }
    private var childIndent: CGFloat { indented ? 38 : 22 }

    private func isWanted(_ trigger: String) -> Bool { wanted.contains("\(key).\(trigger)") }

    /// The child rows, in order: those that do something or are set here, then any just added.
    private var children: [AppButton.Child] {
        [state.doubleClick, state.hold].filter { state.shows($0) || isWanted($0.name) }
    }

    var body: some View {
        let children = children
        let clickTarget = BindingTarget(button: key)
        let note = source.map { source in
            ActionButton.inherited(state.click, inheriting: state.clickInheritedLabel, source: source)
                .note { choose(Self.sameAs, clickTarget, state.click) }
        } ?? nil
        let othersApply = children.contains { $0.isSet }
        let click = pickerButton(state.click, target: clickTarget,
                                 inherited: source == nil ? nil : (state.clickInheritedLabel, state.clickInheritedSpokenLabel),
                                 allowsDefault: offersMouseDefault && (!othersApply || state.canLeaveClickToMouse), allowsGesture: true,
                                 row: PickerEntry.Row(clickOwnsButton: state.effectiveClick.isWhileHeld, othersApply: othersApply))
        if children.isEmpty {
            LabeledContent { click } label: { RowLabel(title, help: help, note: note) }
                .overridable(note, help: help)
                .padding(.leading, indented ? 16 : 0)
                .rowMark(mark)
                .id(key)
        } else {
            let isExpanded = Binding(get: { expanded.contains(key) },
                                     set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
            let summary = state.summary ?? help
            LabeledContent { click } label: {
                DisclosureLabel(title: title, help: isExpanded.wrappedValue ? help : summary, note: note,
                                spokenTitle: "\(title), more ways to press", isExpanded: isExpanded)
            }
            .overridable(note, help: summary)
            .padding(.leading, indented ? 16 : 0)
            .rowMark(mark)
            .id(key)
            if isExpanded.wrappedValue {
                ForEach(children, id: \.name) { child in childRow(child) }
            }
        }
    }

    /// The "Same as …" choice a row's note makes.
    static let sameAs = PickerEntry(id: "inherit", label: "", group: nil, kind: .set(.standard))

    @ViewBuilder
    private func childRow(_ child: AppButton.Child) -> some View {
        let target = BindingTarget(button: key, direction: child.name)
        // At the top level a trigger left out does nothing, so the pop-up shows that.
        let own = source == nil ? child.effective : child.own
        let note = source.map { source in
            ActionButton.inherited(child.own, inheriting: child.inheritedLabel, source: source, trigger: true)
                .note { choose(Self.sameAs, target, child.own) }
        } ?? nil
        let help: String? = switch child.name {
        case "doubleClick": Triggers.doubleClickCaption(milliseconds: doubleClickMs)
        case _ where child.effective == .gesture: "Hold the button and move the mouse. Release without moving to click."
        default: nil
        }
        LabeledContent {
            pickerButton(own, target: target, inherited: source == nil ? nil : (child.inheritedLabel, child.inheritedLabel),
                         allowsDefault: false, allowsGesture: false, row: PickerEntry.Row(trigger: child.name))
        } label: {
            RowLabel(Gesture.label(child.name), help: help, note: note, spokenTitle: target.title + spokenSuffix)
        }
        .overridable(note, help: help)
        .padding(.leading, childIndent)
        if child.name == "hold" {
            ForEach(state.directions, id: \.name) { direction in directionRow(direction) }
        }
    }

    @ViewBuilder
    private func directionRow(_ direction: AppButton.Trigger) -> some View {
        let target = BindingTarget(button: key, direction: direction.name)
        let own = source == nil ? (direction.isOwn ? direction.own : .named("none")) : direction.own
        let note = source.map { source in
            ActionButton.inherited(direction, source: source).note { choose(Self.sameAs, target, direction.own) }
        } ?? nil
        LabeledContent {
            pickerButton(own, target: target,
                         inherited: source == nil ? nil : (direction.inheritedLabel, direction.inheritedSpokenLabel),
                         allowsDefault: false, allowsGesture: false, row: PickerEntry.Row(trigger: direction.name))
        } label: {
            RowLabel(Gesture.label(direction.name), note: note, spokenTitle: target.title + spokenSuffix)
        }
        .overridable(note, help: nil)
        .padding(.leading, childIndent + 16)
    }

    private func pickerButton(_ action: ButtonAction, target: BindingTarget, inherited: (String, String)?,
                              allowsDefault: Bool, allowsGesture: Bool, row: PickerEntry.Row) -> some View {
        let id = target.direction.map { "\(key).\($0)" } ?? key
        return ActionButton(
            action: action,
            allowsDefault: allowsDefault,
            allowsGesture: allowsGesture,
            isPresented: Binding(get: { presented == id }, set: { open in
                presented = open ? id : nil
                if open { opened(target) }
            }),
            choose: { entry in pick(entry, for: target, current: action) },
            accessibilityName: target.title + spokenSuffix,
            sameAsInherited: inherited?.0,
            spokenInherited: inherited?.1,
            source: source ?? InheritedScope.mouseSettings,
            scope: scope,
            row: row)
    }

    private func pick(_ entry: PickerEntry, for target: BindingTarget, current: ButtonAction) {
        switch entry.kind {
        case .trigger(let trigger):
            // A row for it, open, its picker next: nothing is written until an action is chosen.
            wanted.insert("\(key).\(trigger)")
            expanded.insert(key)
            let id = "\(key).\(trigger)"
            DispatchQueue.main.async { presented = id }
        case .gesture:
            expanded.insert(key)
            choose(entry, BindingTarget(button: key, direction: "hold"), current)
        case .set(let action):
            if target.direction != nil, [.standard, .named("none")].contains(action) {
                wanted.remove("\(key).\(target.direction ?? "")")
            }
            choose(entry, target, current)
        case .shortcut, .command:
            choose(entry, target, current)
        }
    }
}
