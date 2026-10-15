import AppKit
import PureMouseKit
import SwiftUI

/// A form row's label: the setting's name, and its explanation underneath in the grouped form's
/// secondary style.
struct RowLabel: View {
    let title: String
    var help: String?
    /// Shown after the help when the key is absent and the mouse keeps its own setting.
    var mouseDefault = false

    init(_ title: String, help: String? = nil, mouseDefault: Bool = false) {
        self.title = title
        self.help = help
        self.mouseDefault = mouseDefault
    }

    var body: some View {
        Text(title)
        if let caption = [help, mouseDefault ? "Mouse default." : nil].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
            Text(caption)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A slider with words at each end and its value on the right, e.g. Slow ——●—— Fast  1.0×.
struct ValueSlider: View {
    let title: String
    var help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let format: (Double) -> String
    var width: CGFloat = 170

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                // No `step:`: macOS would draw a tick per step. The binding snaps instead.
                Slider(value: $value, in: range) {
                    Text(title)
                } minimumValueLabel: {
                    Text(low).font(.subheadline).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(high).font(.subheadline).foregroundStyle(.secondary)
                }
                .labelsHidden()
                .frame(width: width)
                .accessibilityValue(format(value))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 46, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            RowLabel(title, help: help)
        }
    }
}

extension AppModel {
    /// A binding to a numeric config key, showing `fallback` when absent. Writes are debounced.
    func number(_ path: [String], default fallback: Double, step: Double) -> Binding<Double> {
        Binding {
            self.config.double(path) ?? fallback
        } set: {
            self.set(Format.snap($0, step: step), at: path, debounce: true)
        }
    }

    func toggle(_ path: [String], default fallback: Bool) -> Binding<Bool> {
        Binding {
            self.config.bool(path) ?? fallback
        } set: {
            self.set($0, at: path)
        }
    }
}

/// The yellow-triangle notice at the top of a pane.
struct Banner<Actions: View>: View {
    let title: String
    let message: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .yellow
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(tint)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message).foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            HStack { actions }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The notices every pane shows: PureMouse off, a config error, Logi Options+, and (for panes
/// whose settings need it) a missing Accessibility grant.
struct PaneBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(\.app) private var app
    var needsAccessibility = false

    var body: some View {
        if model.statusTooNew {
            Section {
                Banner(title: "Update PureMouse", message: "This menu bar app is older than the PureMouse running now. Install the latest release.") {
                    Button("Releases") { NSWorkspace.shared.open(Links.releases) }
                }
            }
        }
        if !model.daemonRunning {
            Section {
                Banner(title: "PureMouse is off", message: "The mouse works as it does without PureMouse. Changes here apply when it starts.",
                       symbol: "pause.circle.fill", tint: .secondary) {
                    Button("Start PureMouse") { Lifecycle.perform(.register) }
                }
            }
        }
        if let error = model.configError {
            Section {
                Banner(title: "The config file has an error",
                       message: error + "\nPureMouse keeps using the last config that worked. Fix the file to edit settings here.",
                       symbol: "xmark.octagon.fill", tint: .red) {
                    VStack(alignment: .trailing) {
                        Button("Open Config") { NSWorkspace.shared.open(Paths.config) }
                        if model.canRestoreLastWorking {
                            Button("Restore Last Working") { model.restoreLastWorking() }
                        }
                    }
                }
            }
        }
        if let error = model.writeError {
            Section {
                Banner(title: "That change was not saved", message: error, symbol: "exclamationmark.triangle.fill", tint: .yellow) {
                    EmptyView()
                }
            }
        }
        if model.logiOptionsRunning {
            Section {
                Banner(title: "Logi Options+ is running", message: "Only one app can control the buttons. Quit Logi Options+ or remove it.") {
                    Button("How to Remove") { NSWorkspace.shared.open(Links.logiOptions) }
                }
            }
        }
        if needsAccessibility, model.accessibilityMissing {
            Section {
                Banner(title: "Accessibility is not allowed",
                       message: "Wheels and buttons stay native until it is. PureMouse restarts itself once it is allowed.") {
                    Button("Open Settings…") { app?.openPrivacy(.accessibility) }
                }
            }
        }
    }
}

/// A right-aligned button under the last group, like System Settings' "Restore Defaults".
struct FooterButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        HStack {
            Spacer()
            Button(title, action: action)
        }
        .padding(.top, 4)
    }
}

/// A disclosure triangle and title for a form row whose children follow as rows of their own,
/// so each child keeps the grouped form's height and separators (a `DisclosureGroup` packs them).
struct DisclosureLabel: View {
    let title: String
    var help: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let help { Text(help).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

extension View {
    /// Indents a disclosed child row past its parent's triangle.
    func disclosedRow() -> some View { padding(.leading, 22) }
}
