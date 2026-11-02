import PureMouseAppSupport
import SwiftUI

/// How the shortcut and command editors (`ShortcutSheet`, `CommandSheet`) open: as a sheet over a
/// pane, or, inside a sheet such as an app's, as a popover anchored to the row, since no sheet
/// opens from a sheet (docs/ui-design.md, Disclosure). The rows that offer them read it.
enum EditorPresentation {
    case sheet, popover
}

extension EnvironmentValues {
    @Entry var editorPresentation = EditorPresentation.sheet
}

extension View {
    /// Hosts the editor `request` asks for as a sheet over this view, when editors are sheets.
    func actionEditorSheet(_ request: Binding<SheetRequest?>,
                           save: @escaping (ButtonAction, BindingTarget) -> Void) -> some View {
        modifier(EditorSheet(request: request, save: save))
    }

    /// Anchors the editor for `target` to this row, when editors are popovers.
    func actionEditorPopover(_ request: Binding<SheetRequest?>, for target: BindingTarget,
                             save: @escaping (ButtonAction, BindingTarget) -> Void) -> some View {
        modifier(EditorPopover(request: request, target: target, save: save))
    }
}

private struct EditorSheet: ViewModifier {
    @Environment(\.editorPresentation) private var presentation
    @Binding var request: SheetRequest?
    let save: (ButtonAction, BindingTarget) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { presentation == .sheet ? request : nil }, set: { request = $0 })) {
            ActionEditor(request: $0, save: save)
        }
    }
}

private struct EditorPopover: ViewModifier {
    @Environment(\.editorPresentation) private var presentation
    @Binding var request: SheetRequest?
    let target: BindingTarget
    let save: (ButtonAction, BindingTarget) -> Void

    func body(content: Content) -> some View {
        content.popover(item: Binding(get: { presentation == .popover && request?.target == target ? request : nil },
                                      set: { request = $0 }),
                        arrowEdge: .bottom) {
            ActionEditor(request: $0, save: save)
        }
    }
}

/// The editor a request names, saving what it records as the target's action.
private struct ActionEditor: View {
    let request: SheetRequest
    let save: (ButtonAction, BindingTarget) -> Void

    var body: some View {
        switch request.kind {
        case .shortcut: ShortcutSheet(request: request) { save(.keys($0), request.target) }
        case .command: CommandSheet(request: request) { save(.run($0), request.target) }
        }
    }
}
