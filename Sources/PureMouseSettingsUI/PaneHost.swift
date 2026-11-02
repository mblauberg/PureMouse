import PureMouseAppSupport
import SwiftUI

private struct SettingsKey: EnvironmentKey {
    static let defaultValue: SettingsContext? = nil
}

extension EnvironmentValues {
    var settings: SettingsContext? {
        get { self[SettingsKey.self] }
        set { self[SettingsKey.self] = newValue }
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
