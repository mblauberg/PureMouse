import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// A known mouse in General › Status: its name, what it is doing now ("USB receiver · Battery 80%
/// · Computer 1", or that its settings are being applied or were not), and an (i) button that opens
/// About This Mouse. Read-only: nothing here writes the config or opens a HID device.
struct DeviceRow: View {
    let device: Status.Device
    /// Opens the sheet when the row appears (a dev hook only).
    var opensAtAppear = false
    @State private var showingDetails = false

    var body: some View {
        LabeledContent {
            Button { showingDetails = true } label: {
                // The padding is inside the label so the button's frame, its hit target, is 20 pt or more.
                Image(systemName: "info.circle").padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // The sheet's own title is the name; the button is named for the mouse it opens.
            .accessibilityLabel(device.name)
            .help("About this mouse")
        } label: {
            Text(device.name)
            Text(StatusText.row(device))
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

    var body: some View {
        if let device {
            let details = DeviceDetails(device, version: Locations.version)
            AdvancedSheet(title: device.name) {
                Section {
                    ForEach(details.rows) { row in
                        LabeledContent(row.label) {
                            VStack(alignment: .trailing) {
                                ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 4) {
                                        if line.current { Image(systemName: "checkmark") }
                                        Text(line.text)
                                    }
                                }
                            }
                            .multilineTextAlignment(.trailing)
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
