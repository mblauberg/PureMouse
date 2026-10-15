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
            Text("Offline. No account, no network, no telemetry.")
                .padding(.top, 2)
            HStack(spacing: 18) {
                Link("GitHub", destination: Links.repository)
                Link("Releases", destination: Links.releases)
                Link("MIT Licence", destination: Links.licence)
            }
            .padding(.top, 2)
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

    /// The app icon in the window's appearance: macOS 26 draws it light or dark from the same
    /// Icon Composer file, but only when the drawing appearance says which, so draw it under one.
    private static func icon(dark: Bool) -> NSImage {
        var source = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        #if DEBUG
        // `swift run` from the repository has no bundle icon.
        if Bundle.main.bundleIdentifier == nil, let icon = NSImage(contentsOfFile: "assets/AppIcon.icns") { source = icon }
        #endif
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return NSImage(size: NSSize(width: 112, height: 112), flipped: false) { rect in
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                source.draw(in: rect)
            }
            return true
        }
    }
}
