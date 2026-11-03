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

    /// Every notice that applies, as rows. Off and paused are the PureMouse row itself (its Start
    /// button and its switch).
    private var notices: [Notice] {
        BannerPlan.generalItems(for: BannerPlan.State(model: model, needsAccessibility: true))
    }

    /// The mice the daemon knows, only while it runs: a status file outlives it.
    private var devices: [Status.Device] { DeviceRow.shown(model.devices, daemonRunning: model.daemonRunning) }

    var body: some View {
        PaneForm {
            Section("Status") {
                runningRow
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    #if DEBUG
                    DeviceRow(device: device, opensAtAppear: index == 0 && DevHooks.sheet(on: "general") == .aboutMouse)
                    #else
                    DeviceRow(device: device)
                    #endif
                }
                ForEach(notices, id: \.self) { NoticeRow(notice: $0) }
            }

            Section {
                Toggle(isOn: Binding(get: { openAtLogin.isOn }, set: { perform(.openAtLogin($0)) })) {
                    RowLabel("Open at login")
                }
                .accessibilityLabel("Open at login")
                .disabled(model.locations.daemon == nil)
                if openAtLogin.needsApproval {
                    LabeledContent {
                        Button("Open Login Items Settings…") { NSWorkspace.shared.open(OpenAtLogin.settingsURL) }
                    } label: {
                        RowLabel("Approve PureMouse", help: "In System Settings › General › Login Items, allow PureMouse to run in the background.")
                    }
                }
                Toggle(isOn: Binding(get: { showsInMenuBar }, set: { setShowsInMenuBar($0) })) {
                    RowLabel("Show in menu bar", help: "Battery alerts and update checks keep running when it's hidden.")
                }
                .accessibilityLabel("Show in menu bar")
                .help("Open PureMouse from Applications to get back here.")
                .disabled(model.locations.daemon == nil)
                lowBatteryRow
            }

            Section {
                PermissionRow(title: "Accessibility", help: "Lets PureMouse scroll, press shortcuts and swipe for you.",
                              granted: model.daemonRunning ? model.status?.permissions.accessibility : nil)
                PermissionRow(title: "Input Monitoring", help: "Needed for Bluetooth mice.",
                              granted: model.daemonRunning ? model.status?.permissions.inputMonitoring : nil,
                              needed: model.inputMonitoringNeeded)
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
        .onChange(of: devices.map(\.id)) { settings?.refit() }
        .onChange(of: notificationsDenied) { settings?.refit() }
        .sheet(isPresented: $showingAdvanced) {
            GeneralAdvancedSheet().environment(model)
        }
        #if DEBUG
        .onAppear { if DevHooks.sheet(on: "general") == .advanced { showingAdvanced = true } }
        #endif
    }

    // MARK: Rows

    private var runState: RunState { RunState(daemonRunning: model.daemonRunning, paused: model.paused) }

    /// Pause or resume is the switch, on the daemon's control (as the menu's item does); Start is
    /// offered only while PureMouse is off, the recovery when it isn't running.
    private var runningRow: some View {
        let state = runState
        return LabeledContent {
            HStack {
                Label(state.word, systemImage: state.symbol)
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
                    .labelStyle(StatusLabelStyle())
                if let start = state.button {
                    Button("Start") { setRunning(start) }
                        .disabled(changingRunning || model.locations.daemon == nil)
                } else {
                    // The switch names itself; VoiceOver reads the state word beside it first. An
                    // accessibility value on it would make it a plain toggle, not the form's switch.
                    Toggle("PureMouse", isOn: Binding(get: { state.isOn },
                                                      set: { on in state.toggled(on).map { model.setPaused($0 == .paused) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("PureMouse")
                }
            }
        } label: {
            RowLabel("PureMouse")
        }
    }

    /// The menu bar app posts the notifications, with or without its icon (it runs windowless when
    /// the icon is hidden). While macOS has them off the switch is disabled and keeps what was
    /// chosen, and Open Notification Settings… sits in the same row, before the switch.
    private var lowBatteryRow: some View {
        let help = notificationsDenied ? "Off for PureMouse in System Settings."
            : "Tells you when the battery falls to 20% and 5%."
        let isOn = Binding(get: { model.lowBatteryNotificationsOn }, set: { setLowBatteryNotifications($0) })
        return Group {
            if notificationsDenied {
                LabeledContent {
                    HStack(spacing: 12) {
                        // Beside the switch, not inside its label: a disabled toggle disables its label's button too.
                        Button("Open Notification Settings…") { NSWorkspace.shared.open(NotificationPermission.settingsURL) }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        Toggle("Low battery notifications", isOn: isOn)
                            .labelsHidden()
                            // Outside the form's own toggle row the style is not inherited.
                            .toggleStyle(.switch)
                            .accessibilityLabel("Low battery notifications")
                            .disabled(true)
                    }
                } label: {
                    RowLabel("Low battery notifications", help: help)
                }
            } else {
                Toggle(isOn: isOn) {
                    RowLabel("Low battery notifications", help: help)
                }
                .accessibilityLabel("Low battery notifications")
                .disabled(model.readOnly)
            }
        }
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
                    Text("This resets every mouse and every app, not only the mouse chosen on Mouse. Buttons, scrolling and pointer settings return to PureMouse's defaults. The current config file is saved as \(model.backupName), replacing any earlier backup. Open at login and the menu bar icon don't change.")
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
    /// Whether anything PureMouse does now needs it; a permission that is neither granted nor
    /// needed (Input Monitoring with no Bluetooth mouse) reads "Not needed". The row only reports:
    /// a permission that is not allowed has its notice above, with the button that opens its pane.
    var needed = true

    var body: some View {
        let state = PermissionState(granted: granted, needed: needed)
        LabeledContent {
            HStack(spacing: 8) {
                switch state {
                case .allowed:
                    Label(state.word, systemImage: "checkmark.circle.fill")
                case .notAllowed:
                    Label(state.word, systemImage: "exclamationmark.triangle.fill")
                case .notNeeded, .unavailable:
                    Text(state.word)
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
