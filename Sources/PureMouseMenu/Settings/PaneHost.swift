import SwiftUI

/// One Settings pane: a grouped form at the window's fixed width, sized to its content so the
/// window fits it.
struct PaneHost: View {
    let pane: SettingsPane
    let app: AppController

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(app: app)
            case .buttons: ButtonsPane()
            case .scrolling: ScrollingPane()
            case .pointer: PointerPane()
            case .about: AboutPane()
            }
        }
        .frame(width: SettingsWindowController.width)
        .environment(\.app, app)
    }
}

private struct AppKey: EnvironmentKey {
    static let defaultValue: AppController? = nil
}

extension EnvironmentValues {
    var app: AppController? {
        get { self[AppKey.self] }
        set { self[AppKey.self] = newValue }
    }
}

/// A grouped form that reports its full height, so the window grows instead of scrolling.
struct PaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
