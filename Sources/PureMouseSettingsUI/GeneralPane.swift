import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var login: LoginStatus?  // read on appear; nil until `login-status` answers
    @State private var changingRunning = false
    @State private var showsInMenuBar = true
    @State private var confirmingReset = false
    @State private var notificationsDenied = false
    @State private var deniedWatch: NotificationPermission.Watch?

    var body: some View {
        PaneForm {
            PaneBanners()
            Section {
                Toggle(isOn: Binding(get: { openAtLogin.isOn }, set: { perform(.openAtLogin($0)) })) {
                    RowLabel("Open at login", help: "Turning it off does not stop PureMouse.")
                }
                .accessibilityLabel("Open at login")
                if openAtLogin.needsApproval {
                    LabeledContent {
                        Button("Open Login Items…") { NSWorkspace.shared.open(OpenAtLogin.settingsURL) }
                    } label: {
                        RowLabel("Approve PureMouse", help: "In System Settings › General › Login Items, allow PureMouse to run in the background.")
                    }
                }
                LabeledContent {
                    HStack {
                        Text(model.daemonRunning ? "Yes" : "No").foregroundStyle(.secondary)
                        Button(model.daemonRunning ? "Stop" : "Start") { setRunning(!model.daemonRunning) }
                            .disabled(changingRunning)
                    }
                } label: {
                    RowLabel("PureMouse is running", help: "Stop returns the mouse to normal. Open at login stays as it is.")
                }
                Toggle(isOn: Binding(get: { showsInMenuBar }, set: { setShowsInMenuBar($0) })) {
                    RowLabel("Show in menu bar", help: "When hidden, open PureMouse from Applications to get back here.")
                }
                .accessibilityLabel("Show in menu bar")
            }
            .disabled(model.locations.daemon == nil)

            Section {
                Toggle(isOn: Binding(get: { model.lowBatteryNotificationsOn },
                                     set: { setLowBatteryNotifications($0) })) {
                    RowLabel("Low battery notification",
                             help: notificationsDenied
                                ? "Notifications for PureMouse are off in System Settings. Needs the menu bar icon shown."
                                : "Tells you when the battery falls to 20% and 5%. Needs the menu bar icon shown.")
                }
                .accessibilityLabel("Low battery notification")
                Toggle(isOn: Binding(get: { model.config.universalControlHandOff },
                                     set: { on in model.update { $0.universalControlHandOff = on } })) {
                    RowLabel("Work with Universal Control",
                             help: "While the pointer is on another Mac, the mouse scrolls and clicks there as it does without PureMouse.")
                }
                .accessibilityLabel("Work with Universal Control")
            }
            .disabled(model.readOnly)

            Section("Permissions") {
                PermissionRow(title: "Accessibility", help: "Lets PureMouse scroll, press shortcuts and swipe for you.",
                              granted: model.daemonRunning ? model.status?.permissions.accessibility : nil) {
                    NSWorkspace.shared.open(PrivacyPane.accessibility.url)
                }
                PermissionRow(title: "Input Monitoring", help: "Needed for Bluetooth. The USB receiver works without it.",
                              granted: model.daemonRunning ? model.status?.permissions.inputMonitoring : nil) {
                    NSWorkspace.shared.open(PrivacyPane.inputMonitoring.url)
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
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.locations.config]) }
                    }
                } label: {
                    Text("Config file")
                    Text(Format.tildePath(model.locations.config.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.locations.config.path)
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
            refreshLogin()
            showsInMenuBar = model.locations.showsInMenuBar
            // The menu bar app records the answer as it learns it, and may learn it while this shows.
            notificationsDenied = NotificationPermission.denied(in: NotificationPermission.menuDefaults)
            deniedWatch = NotificationPermission.Watch(NotificationPermission.menuDefaults) { notificationsDenied = $0 }
        }
        .onDisappear { deniedWatch = nil }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset All Settings", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every button, scrolling and pointer setting goes back to how the mouse works without PureMouse. Unless it is empty, the current config file is kept as \(model.backupName), replacing an earlier backup.")
        }
    }

    private var openAtLogin: OpenAtLogin { OpenAtLogin(login) }

    /// Reads the answer from `puremouse login-status`; until it arrives, or if it cannot be had, off.
    private func refreshLogin() {
        Lifecycle.readLoginStatus(daemon: model.locations.daemon) { login = $0 }
    }

    /// Runs the command for a control, then reads `login-status` again, so the switch shows what is
    /// so whether or not it worked.
    private func perform(_ action: LoginAction) {
        model.perform(action.command, then: { refreshLogin() }, otherwise: { refreshLogin() })
    }

    private func setRunning(_ on: Bool) {
        changingRunning = true
        model.perform(LoginAction.running(on).command, then: { changingRunning = false },
                      otherwise: { changingRunning = false })
    }

    /// The menu bar app posts the notifications, and macOS asks per app, so the menu bar app asks
    /// for permission when it sees this turned on, and records the answer for this pane.
    private func setLowBatteryNotifications(_ on: Bool) {
        model.set(on ? nil : false, at: ["notifications", "lowBattery"])
    }

    /// Runs `menu on` or `off` now. This app is not in the menu agent's process group, so removing
    /// that agent leaves it open. The switch moves at once, and goes back to what is so (the
    /// daemon's `menu-hidden` marker) if the command fails.
    private func setShowsInMenuBar(_ on: Bool) {
        showsInMenuBar = on
        guard on != model.locations.showsInMenuBar else { return }
        model.flush()
        model.perform(on ? .menuOn : .menuOff, then: {}, otherwise: { showsInMenuBar = model.locations.showsInMenuBar })
    }

    private func openConfig() {
        model.createConfigIfMissing()
        NSWorkspace.shared.open(model.locations.config)
    }

    private func showLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: model.locations.log.path) {
            NSWorkspace.shared.open([model.locations.log], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([model.locations.log.deletingLastPathComponent()])
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
