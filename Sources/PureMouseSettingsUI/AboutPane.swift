import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var daemonVersion: String? { model.status?.version }

    var body: some View {
        VStack(spacing: 10) {
            // The PNGs are the squircle edge to edge; an app icon's squircle is 824 of its 1024
            // points, so it is drawn at that share of the slot, the size the Finder draws it.
            Image(nsImage: Self.icon(dark: colorScheme == .dark))
                .resizable()
                .frame(width: 112 * 824 / 1024, height: 112 * 824 / 1024)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("PureMouse")
                .font(.title2.weight(.semibold))
            Text("Version \(Locations.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let daemonVersion, daemonVersion != Locations.version, Locations.version != "dev" {
                // Quit PureMouse stops the background process and opening the app starts it again
                // from the installed copy (`puremouse register`), so the new version runs.
                Label("PureMouse \(daemonVersion) is still running. Quit and reopen PureMouse to finish updating.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            UpdateRow()
                .padding(.top, 6)
            HStack(spacing: 8) {
                link("GitHub", Links.repository)
                separator
                link("Releases", Links.releases)
                separator
                link("Licence", Links.licence)
                separator
                link("Support PureMouse", Links.sponsors)
            }
            .padding(.top, 6)
            VStack(spacing: 2) {
                Text("No account, no telemetry. The network is used only to check for and download updates.")
                Text("Not affiliated with Logitech.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
        }
        .padding(.top, 32)
        .padding(.bottom, 36)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    /// A link whose hit target is 20 pt tall: its line of text is 16, and the `.link` button style
    /// takes the label's text alone as its frame. VoiceOver still finds it as a link (`AXLink`), and
    /// it shows the pointing hand where macOS 15 can say so, as `Link` does.
    private func link(_ title: String, _ destination: URL) -> some View {
        Button { openURL(destination) } label: { Text(title).padding(.vertical, 2).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityAddTraits(.isLink)
            .modifier(LinkPointer())
    }

    /// Between links; read aloud as nothing.
    private var separator: some View {
        Text("\u{00B7}")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// The app icon in the window's appearance. `NSWorkspace` hands back the light rendering of
    /// the Icon Composer file whatever the drawing appearance, so the bundle carries both as
    /// 256 px PNGs (the README's). Named with their extension: by name alone, `AppIcon` is the
    /// `.icns`, which has the icon grid's margin built in and the PNGs do not.
    private static func icon(dark: Bool) -> NSImage {
        let name = dark ? "AppIcon-dark" : "AppIcon"
        #if DEBUG
        // `swift run` from the repository has no bundle resources.
        if Bundle.main.bundleIdentifier == nil, let icon = NSImage(contentsOfFile: "assets/\(name).png") { return icon }
        #endif
        return Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}

/// What the About switch does: reads and writes the answer in the menu app's preferences and
/// nothing else. It makes no request; the menu app hears the write and arms or cancels its schedule.
struct AutomaticUpdates {
    let preferences: UpdatePreferences?
    var isOn: Bool { preferences?.automatic ?? false }
    func set(_ on: Bool) { preferences?.automatic = on }
}

/// Update and Relaunch: Settings is a separate app, and installing is the menu bar app's (one
/// installer, docs/adr/0022). This writes the request into its preferences; the menu app asks the
/// person, installs, relaunches, and writes one line of what it is doing back (`installStatus`).
@MainActor
struct InstallRequest {
    let preferences: UpdatePreferences?
    /// Whether a menu bar app is there to hear it: with its icon hidden, or not running, nothing is.
    var menuIsRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Companion.menuLabel).isEmpty
    }
    /// The question is asked by the menu app, so it is handed the focus.
    var yieldFocus: () -> Void = { NSApp.yieldActivation(toApplicationWithBundleIdentifier: Companion.menuLabel) }

    var isOffered: Bool { preferences != nil && menuIsRunning() }
    var status: String? { preferences?.installStatus }
    var inProgress: Bool { status?.hasPrefix("Updating") == true }

    func ask(for release: UpdateCheck.Release) {
        guard isOffered, !inProgress else { return }
        preferences?.installStatus = nil
        yieldFocus()
        preferences?.installRequest = release
    }
}

/// "Check for Updates": one request when pressed. "Check for updates automatically" is the answer
/// to the menu bar app's question (`UpdateQuestion`), kept in its preferences, where the menu app
/// runs the daily check from (`UpdateReminders`); this process makes no request unless the button
/// is pressed.
private struct UpdateRow: View {
    @State private var checking = false
    @State private var outcome: UpdateCheck.Outcome?
    @State private var automatic = false
    @State private var watch: UpdatePreferences.Watch?
    @State private var statusWatch: UpdatePreferences.Watch?
    @State private var installStatus: String?

    private let preferences = NotificationPermission.menuDefaults.map { UpdatePreferences($0) }
    private var answer: AutomaticUpdates { AutomaticUpdates(preferences: preferences) }
    private var install: InstallRequest { InstallRequest(preferences: preferences) }

    var body: some View {
        VStack(spacing: 6) {
            Button(checking ? "Checking…" : "Check for Updates") { check() }
                .disabled(checking)
                .accessibilityLabel("Check for Updates")
            Toggle("Check for updates automatically", isOn: Binding(get: { automatic }, set: { setAutomatic($0) }))
                .toggleStyle(.switch)
                .accessibilityLabel("Check for updates automatically")
            switch outcome {
            case .upToDate?:
                Text("PureMouse is up to date").font(.callout).foregroundStyle(.secondary)
            case .available(let release)?:
                HStack(spacing: 8) {
                    Text("PureMouse \(release.version.parts.map(String.init).joined(separator: ".")) is available")
                        .font(.callout)
                    Button("View Release") { NSWorkspace.shared.open(release.page) }
                    if install.isOffered {
                        Button("Update and Relaunch") { install.ask(for: release) }
                            .disabled(install.inProgress)
                    }
                }
                if let installStatus {
                    Text(installStatus).font(.callout).foregroundStyle(.secondary)
                }
            case .failed?:
                Text("Couldn't check for updates. Try again later.").font(.callout).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            // The menu bar app stores the answer to its question, and may do so while this shows.
            automatic = answer.isOn
            watch = preferences.map { preferences in
                UpdatePreferences.Watch(preferences.defaults) { automatic = answer.isOn }
            }
            // The menu bar app says what it is doing with a requested update.
            installStatus = install.status
            statusWatch = preferences.map { preferences in
                UpdatePreferences.Watch(preferences.defaults, .installStatus) { installStatus = install.status }
            }
        }
        .onDisappear { watch = nil; statusWatch = nil }
    }

    private func setAutomatic(_ on: Bool) {
        automatic = on
        answer.set(on)
    }

    private func check() {
        checking = true
        outcome = nil
        Task {
            let result = await UpdateCheck.fetch(current: Locations.version)
            outcome = result
            checking = false
        }
    }
}

/// The pointing hand over a link (macOS 15 and later; macOS 14 shows the arrow).
struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}
