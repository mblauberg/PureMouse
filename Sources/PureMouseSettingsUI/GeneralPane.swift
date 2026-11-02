import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// General (docs/ui-design.md, Layout): Status, the three switches, Permissions, and an Advanced…
/// sheet with Universal Control, the files and Reset All Settings….
struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    @State private var login: LoginStatus?  // read on appear; nil until `login-status` answers
    @State private var changingRunning = false
    @State private var showsInMenuBar = true
    @State private var notificationsDenied = false
    @State private var deniedWatch: NotificationPermission.Watch?
    @State private var showingAdvanced = false

    /// Every notice that applies, as rows. Off is the PureMouse row itself, with its Start button.
    private var notices: [Notice] {
        BannerPlan.items(for: BannerPlan.State(model: model, needsAccessibility: true)).filter { $0 != .off }
    }

    var body: some View {
        PaneForm {
            Section("Status") {
                runningRow
                ForEach(notices, id: \.self) { NoticeRow(notice: $0) }
            }

            Section {
                Toggle(isOn: Binding(get: { openAtLogin.isOn }, set: { perform(.openAtLogin($0)) })) {
                    RowLabel("Open at login", help: "Turning it off doesn't stop PureMouse.")
                }
                .accessibilityLabel("Open at login")
                .disabled(model.locations.daemon == nil)
                if openAtLogin.needsApproval {
                    LabeledContent {
                        Button("Open Login Items Settings") { NSWorkspace.shared.open(OpenAtLogin.settingsURL) }
                    } label: {
                        RowLabel("Approve PureMouse", help: "In System Settings › General › Login Items, allow PureMouse to run in the background.")
                    }
                }
                Toggle(isOn: Binding(get: { showsInMenuBar }, set: { setShowsInMenuBar($0) })) {
                    RowLabel("Show in menu bar", help: "When hidden, open PureMouse from Applications to get back here.")
                }
                .accessibilityLabel("Show in menu bar")
                .disabled(model.locations.daemon == nil)
                lowBatteryRow
            }

            Section {
                PermissionRow(title: "Accessibility", help: "Lets PureMouse scroll, press shortcuts and swipe for you.",
                              granted: model.daemonRunning ? model.status?.permissions.accessibility : nil) {
                    NSWorkspace.shared.open(PrivacyPane.accessibility.url)
                }
                PermissionRow(title: "Input Monitoring", help: "Needed for Bluetooth mice. USB receivers work without it.",
                              granted: model.daemonRunning ? model.status?.permissions.inputMonitoring : nil) {
                    NSWorkspace.shared.open(PrivacyPane.inputMonitoring.url)
                }
            } header: {
                Text("Permissions")
            } footer: {
                PaneFooter(advanced: { showingAdvanced = true })
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
        // Rows come and go with the answers, after the window was sized.
        .onChange(of: openAtLogin.needsApproval) { settings?.refit() }
        .onChange(of: notices) { settings?.refit() }
        .sheet(isPresented: $showingAdvanced) {
            GeneralAdvancedSheet().environment(model)
        }
    }

    // MARK: Rows

    private var runState: RunState { RunState(daemonRunning: model.daemonRunning, paused: model.paused) }

    private var runningRow: some View {
        let state = runState
        return LabeledContent {
            HStack {
                Label(state.word, systemImage: state.symbol)
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
                    .labelStyle(StatusLabelStyle())
                Button(state == .off ? "Start" : "Stop") { setRunning(state.button) }
                    .disabled(changingRunning || model.locations.daemon == nil)
            }
        } label: {
            RowLabel("PureMouse", help: "Stopping returns the mouse to normal. Open at login doesn't change.")
        }
    }

    /// Dimmed while the menu bar icon is hidden: the menu bar app posts the notifications.
    private var lowBatteryRow: some View {
        let needsIcon = !showsInMenuBar
        let help = needsIcon ? "Needs the menu bar icon."
            : notificationsDenied ? "Notifications are off for PureMouse in System Settings."
            : "Tells you when the battery falls to 20% and 5%."
        return LabeledContent {
            HStack {
                if notificationsDenied, !needsIcon {
                    Button("Open System Settings") { NSWorkspace.shared.open(NotificationPermission.settingsURL) }
                        .accessibilityLabel("Allow notifications in System Settings")
                }
                Toggle("Low battery notification", isOn: Binding(get: { model.lowBatteryNotificationsOn },
                                                                 set: { setLowBatteryNotifications($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.readOnly)
            }
        } label: {
            RowLabel("Low battery notification", help: help)
        }
        .disabled(needsIcon)
    }

    // MARK: Actions

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

    private func setRunning(_ action: LoginAction) {
        changingRunning = true
        model.perform(action.command, then: { changingRunning = false },
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
}

/// General's Advanced… sheet: Universal Control, the config file and the log, and Reset All
/// Settings… at its bottom-leading edge.
private struct GeneralAdvancedSheet: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false

    var body: some View {
        AdvancedSheet(title: "Advanced") {
            Section {
                Toggle(isOn: Binding(get: { model.config.universalControlHandOff },
                                     set: { on in model.update { $0.universalControlHandOff = on } })) {
                    RowLabel("Work with Universal Control", help: "On another Mac, the mouse works as it does without PureMouse.")
                }
                .accessibilityLabel("Work with Universal Control")
                .disabled(model.readOnly)
            }
            Section {
                LabeledContent {
                    HStack {
                        Button("Open") { openConfig() }
                            .accessibilityLabel("Open config file")
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.locations.config]) }
                            .accessibilityLabel("Show config file in Finder")
                    }
                } label: {
                    Text("Config file")
                    Text(Format.tildePath(model.locations.config.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.locations.config.path)
                }
                LabeledContent {
                    HStack {
                        Button("Open") { openLog() }
                            .accessibilityLabel("Open log")
                        Button("Show in Finder") { showLogInFinder() }
                            .accessibilityLabel("Show log in Finder")
                    }
                } label: {
                    RowLabel("Log", help: "Useful when something isn't working.")
                }
            }
        } leading: {
            Button("Reset All Settings…") { confirmingReset = true }
                .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
                    Button("Reset All Settings") { model.resetAll() }
                } message: {
                    Text("Buttons, scrolling and pointer settings return to the mouse's defaults. The current config file is saved as \(model.backupName), replacing any earlier backup. Open at login and the menu bar icon don't change.")
                }
        }
    }

    private func openConfig() {
        model.createConfigIfMissing()
        NSWorkspace.shared.open(model.locations.config)
    }

    private var logExists: Bool { FileManager.default.fileExists(atPath: model.locations.log.path) }

    /// In Console; with no log yet, its folder in the Finder.
    private func openLog() {
        guard logExists else { return showLogInFinder() }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([model.locations.log], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private func showLogInFinder() {
        let log = model.locations.log
        NSWorkspace.shared.activateFileViewerSelecting([logExists ? log : log.deletingLastPathComponent()])
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
                case false?:
                    Label("Not allowed", systemImage: "exclamationmark.triangle.fill")
                    Button("Open System Settings", action: open)
                        .accessibilityLabel("Allow \(title) in System Settings")
                case nil:
                    Text("Unavailable while PureMouse is off")
                }
            }
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.secondary)
            .labelStyle(StatusLabelStyle())
        } label: {
            RowLabel(title, help: help)
        }
    }
}

extension RunState {
    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .off: "stop.circle.fill"
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
