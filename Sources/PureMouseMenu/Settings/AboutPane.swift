import AppKit
import SwiftUI

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var daemonVersion: String? { model.status?.version }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: Self.icon(dark: colorScheme == .dark))
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("PureMouse")
                .font(.system(size: 22, weight: .semibold))
            Text("Version \(Paths.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let daemonVersion, daemonVersion != Paths.version, Paths.version != "dev" {
                Label("The running PureMouse is version \(daemonVersion). Reinstall to match.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
            Text("No account, no telemetry. The network is used only when you check for updates.")
                .padding(.top, 2)
            HStack(spacing: 18) {
                Link("GitHub", destination: Links.repository)
                Link("Releases", destination: Links.releases)
                Link("MIT Licence", destination: Links.licence)
            }
            .padding(.top, 2)
            UpdateRow()
                .padding(.top, 6)
            Text("Not affiliated with Logitech.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        }
        .padding(.top, 32)
        .padding(.bottom, 36)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    /// The app icon in the window's appearance. `NSWorkspace` hands back the light rendering of
    /// the Icon Composer file whatever the drawing appearance, so the bundle carries both as
    /// 256 px PNGs (the README's).
    private static func icon(dark: Bool) -> NSImage {
        let name = dark ? "AppIcon-dark" : "AppIcon"
        #if DEBUG
        // `swift run` from the repository has no bundle resources.
        if Bundle.main.bundleIdentifier == nil, let icon = NSImage(contentsOfFile: "assets/\(name).png") { return icon }
        #endif
        return Bundle.main.image(forResource: name) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
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
                Text("Up to date").font(.callout).foregroundStyle(.secondary)
            case .available(let release)?:
                HStack(spacing: 8) {
                    Text("PureMouse \(release.version.parts.map(String.init).joined(separator: ".")) is available")
                        .font(.callout)
                    Button("View Release") { NSWorkspace.shared.open(release.page) }
                }
            case .failed?:
                Text("Couldn\u{2019}t check").font(.callout).foregroundStyle(.secondary)
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
            let result = await UpdateCheck.fetch(current: Paths.version)
            outcome = result
            checking = false
        }
    }
}
