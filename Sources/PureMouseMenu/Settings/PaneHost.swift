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
            case .apps: AppsPane()
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

/// A grouped form whose ideal height is its content's, so the window grows to fit it. When the
/// screen is too short for that (`SettingsTabs.fitWindow` caps the window), the form scrolls.
struct PaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
    }
}
