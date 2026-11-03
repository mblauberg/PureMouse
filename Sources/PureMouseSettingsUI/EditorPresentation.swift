import PureMouseAppSupport
import SwiftUI

extension View {
    /// Hosts the shortcut or command editor `request` asks for as a sheet over this view. The
    /// editors are sheets wherever they open from, an app's page included (docs/ui-design.md,
    /// Disclosure).
    func actionEditorSheet(_ request: Binding<SheetRequest?>,
                           save: @escaping (ButtonAction, BindingTarget) -> Void) -> some View {
        sheet(item: request) { ActionEditor(request: $0, save: save) }
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
