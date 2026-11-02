import AppKit
import PureMouseAppSupport
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
                Text("No account, no telemetry. The network is used only when you check for updates.")
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

/// "Check for Updates": one request when pressed, never in the background.
private struct UpdateRow: View {
    @State private var checking = false
    @State private var outcome: UpdateCheck.Outcome?

    var body: some View {
        VStack(spacing: 6) {
            Button(checking ? "Checking…" : "Check for Updates") { check() }
                .disabled(checking)
                .accessibilityLabel("Check for Updates")
            switch outcome {
            case .upToDate?:
                Text("PureMouse is up to date").font(.callout).foregroundStyle(.secondary)
            case .available(let release)?:
                HStack(spacing: 8) {
                    Text("PureMouse \(release.version.parts.map(String.init).joined(separator: ".")) is available")
                        .font(.callout)
                    Button("View Release") { NSWorkspace.shared.open(release.page) }
                }
            case .failed?:
                Text("Couldn't check for updates. Try again later.").font(.callout).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
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
private struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}
