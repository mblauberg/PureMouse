import AppKit
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    let app: AppController
    @State private var startsAtLogin = Paths.startsAtLogin
    @State private var showsInMenuBar = true
    @State private var confirmingReset = false

    var body: some View {
        PaneForm {
            PaneBanners()
            Section {
                Toggle(isOn: Binding(get: { startsAtLogin }, set: { setStartsAtLogin($0) })) {
                    RowLabel("Start PureMouse at login", help: "Off stops PureMouse now and returns the mouse to normal.")
                }
                Toggle(isOn: Binding(get: { showsInMenuBar }, set: { setShowsInMenuBar($0) })) {
                    RowLabel("Show in menu bar", help: "When hidden, open PureMouse from Applications to get back here.")
                }
            }
            .disabled(Paths.daemon == nil)

            Section("Permissions") {
                PermissionRow(title: "Accessibility", help: "Lets PureMouse scroll, press shortcuts and swipe for you.",
                              granted: model.daemonRunning ? model.status?.permissions.accessibility : nil) {
                    app.openPrivacy(.accessibility)
                }
                PermissionRow(title: "Input Monitoring", help: "Needed for Bluetooth. The USB receiver works without it.",
                              granted: model.daemonRunning ? model.status?.permissions.inputMonitoring : nil) {
                    app.openPrivacy(.inputMonitoring)
                }
                if model.logiOptionsRunning {
                    LabeledContent {
                        HStack {
                            Label("Running", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                            Button("How to Remove") { NSWorkspace.shared.open(Links.logiOptions) }
                        }
                    } label: {
                        RowLabel("Logi Options+", help: "Only one app can control the buttons.")
                    }
                }
            }

            Section {
                LabeledContent {
                    HStack {
                        Button("Open") { openConfig() }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }
                    }
                } label: {
                    Text("Config file")
                    Text(Format.tildePath(Paths.config.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Paths.config.path)
                }
                LabeledContent {
                    Button("Show Log") { showLog() }
                } label: {
                    RowLabel("Log", help: "Useful when something isn't working.")
                }
            } header: {
                Text("Files")
            } footer: {
                FooterButton("Reset All Settings…") { confirmingReset = true }
            }
        }
        .onAppear {
            startsAtLogin = Paths.startsAtLogin
            showsInMenuBar = app.showsStatusItem
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset All Settings", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every button, scrolling and pointer setting goes back to how the mouse works without PureMouse. The config file is emptied.")
        }
    }

    private func setStartsAtLogin(_ on: Bool) {
        if on {
            Lifecycle.perform(.register) { startsAtLogin = Paths.startsAtLogin }
        } else if Alerts.confirm("Stop PureMouse?",
                                 "The mouse returns to normal, the menu bar icon goes, and PureMouse no longer starts at login. Open PureMouse from Applications to start it again.",
                                 action: "Stop PureMouse") {
            model.flush()
            Lifecycle.perform(.unregister) { startsAtLogin = Paths.startsAtLogin }
        }
    }

    private func setShowsInMenuBar(_ on: Bool) {
        showsInMenuBar = on
        app.setMenuBarPreference(on)
    }

    private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { model.resetAll() }
        NSWorkspace.shared.open(Paths.config)
    }

    private func showLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: Paths.log.path) {
            NSWorkspace.shared.open([Paths.log], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.log.deletingLastPathComponent()])
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let help: String
    /// nil while PureMouse is off: only the daemon knows (grants are per process).
    let granted: Bool?
    let open: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch granted {
                case true?:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case false?:
                    Label("Not Allowed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Open Settings…", action: open)
                case nil:
                    Text("Unknown While Off").foregroundStyle(.secondary)
                }
            }
            .labelStyle(StatusLabelStyle())
        } label: {
            RowLabel(title, help: help)
        }
    }
}

/// A status symbol beside its words, so state never relies on colour alone.
struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
