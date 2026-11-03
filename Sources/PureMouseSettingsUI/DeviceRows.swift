import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// A known mouse in General › Status: its name, what it is doing now ("USB receiver · Battery 80%
/// · Computer 1", or that its settings are being applied or were not), and an (i) button that opens
/// About This Mouse. Read-only: nothing here writes the config or opens a HID device.
struct DeviceRow: View {
    let device: Status.Device
    @Environment(AppModel.self) private var model
    /// Opens the sheet when the row appears (a dev hook only).
    var opensAtAppear = false
    @State private var showingDetails = false

    private var notApplied: Bool { device.applied?.state == .notApplied }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if notApplied {
                    Button("Apply Settings Again") { model.applySettingsAgain() }
                        .buttonStyle(.bordered)
                        // Two mice can both be failed: each button is named for its own row.
                        .accessibilityLabel("Apply Settings Again to \(device.name)")
                }
                Button { showingDetails = true } label: {
                    // Vertical padding only: the glyph's trailing edge is the row's, like the switches'.
                    Image(systemName: "info.circle").padding(.vertical, 4).padding(.leading, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // The sheet's own title is the name; the button is named for the mouse it opens.
                .accessibilityLabel("About \(device.name)")
                .help("About this mouse")
            }
        } label: {
            Text(device.name)
            if notApplied {
                Label {
                    Text(StatusText.row(device))
                } icon: {
                    Image(systemName: "exclamationmark.triangle").symbolRenderingMode(.multicolor)
                }
                .labelStyle(StatusLabelStyle())
            } else {
                Text(StatusText.row(device))
            }
        }
        .sheet(isPresented: $showingDetails) {
            AboutMouseSheet(deviceID: device.id)
        }
        #if DEBUG
        .onAppear { if opensAtAppear { showingDetails = true } }
        #endif
    }
}

extension DeviceRow {
    /// The mice General lists: those the daemon knows, only while it runs (a status file outlives
    /// it), so a fresh install lists none.
    static func shown(_ devices: [Status.Device], daemonRunning: Bool) -> [Status.Device] {
        daemonRunning ? devices : []
    }
}

/// About This Mouse: what the daemon reports of one mouse, read-only, with Copy Details for a bug
/// report. The facts a mouse does not report have no row. The sheet follows the live status, and
/// closes itself when the mouse is no longer known.
struct AboutMouseSheet: View {
    let deviceID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var device: Status.Device? { model.devices.first { $0.id == deviceID } }
    private static let checkmarkGutter: CGFloat = 14

    var body: some View {
        if let device {
            let details = DeviceDetails(device, version: Locations.version)
            AdvancedSheet(title: device.name) {
                Section {
                    ForEach(details.rows) { row in
                        LabeledContent(row.label) {
                            // Leading-aligned, with the same gutter on every line of a row that marks one
                            // (the computers), so the names line up whichever one is current.
                            let marks = row.lines.contains { $0.current }
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 4) {
                                        if marks {
                                            Image(systemName: "checkmark")
                                                .opacity(line.current ? 1 : 0)
                                                .frame(width: Self.checkmarkGutter)
                                                .accessibilityHidden(true)  // "This Mac" in the text says it
                                        }
                                        Text(line.text)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            } leading: {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details.copyText, forType: .string)
                }
            }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
