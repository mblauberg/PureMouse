import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI

/// A form row's label: the setting's name, and its explanation underneath in the grouped form's
/// secondary style.
struct RowLabel: View {
    let title: String
    var help: String?
    /// Shown after the help when the key is absent and the mouse keeps its own setting.
    var mouseDefault = false
    /// A control the mouse lacks, kept because its value is set: says so after the help.
    var availability = ControlAvailability.available

    init(_ title: String, help: String? = nil, mouseDefault: Bool = false,
         availability: ControlAvailability = .available) {
        self.title = title
        self.help = help
        self.mouseDefault = mouseDefault
        self.availability = availability
    }

    static let mouseDefaultCaption = "Using the mouse's own setting."

    var body: some View {
        Text(title)
        let parts = [help, mouseDefault ? Self.mouseDefaultCaption : nil, availability.caption]
        if let caption = parts.compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
            Text(caption)
        }
    }
}

/// A pop-up's closed face as the form's own pop-up menus draw it: the value, then the up/down
/// chevrons. One drawing for every pop-up in Settings (`PopUpMenu`, `ActionButton`), so the
/// action rows on Buttons, Scrolling and an app's sheet read alike.
struct PopUpLabel: View {
    let text: String
    var style: HierarchicalShapeStyle = .primary

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(style)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// A standard pop-up for a short list of choices: a `Menu` drawn as a push button around
/// `PopUpLabel`, the same bezel as `ActionButton`. A bare `Picker`
/// in a grouped form can draw as a borderless pull-down with a circled chevron instead.
struct PopUpMenu<Content: View>: View {
    let text: String
    var style: HierarchicalShapeStyle = .primary
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            PopUpLabel(text: text, style: style)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A slider with its words under each end, as System Settings draws them (Slow … Fast), and
/// its value on the right.
struct ValueSlider: View {
    let title: String
    /// What VoiceOver calls the slider, where the title alone is ambiguous (two "Speed" rows).
    var spokenTitle: String?
    var help: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let format: (Double) -> String
    var width: CGFloat = 200
    var availability = ControlAvailability.available
    /// The key is absent and the mouse keeps its own setting (`RowLabel.mouseDefault`).
    var mouseDefault = false

    var body: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                EndLabeledSlider(title: spokenTitle ?? title, value: $value, range: range, low: low, high: high)
                    .frame(width: width)
                    .accessibilityValue(format(value))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            RowLabel(title, help: help, mouseDefault: mouseDefault, availability: availability)
        }
    }
}

/// A plain slider with small words under its ends. No `step:`: macOS would draw a tick per
/// step, so callers snap in their binding instead.
struct EndLabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
            // No words under the ends when there are none to say (Pointer Speed before the mouse
            // has reported its range).
            if !low.isEmpty || !high.isEmpty {
                HStack {
                    Text(low)
                    Spacer(minLength: 8)
                    Text(high)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
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

/// The row under a pane's last group (docs/ui-design.md): Restore Defaults at the leading edge,
/// Advanced… at the trailing edge, either optional. Advanced… opens the pane's `AdvancedSheet`.
/// Goes in the last section's footer, so it scrolls with the form.
///
/// With a `restoreMessage`, Restore Defaults asks first: a confirmation whose button is a plain
/// "Restore Defaults" (chosen on purpose, so not the destructive style) and whose message says
/// what returns to its default.
struct PaneFooter: View {
    var restoreDefaults: (() -> Void)?
    var restoreMessage: String?
    var advanced: (() -> Void)?
    @State private var confirmingRestore = false

    var body: some View {
        HStack {
            if let restoreDefaults {
                Button(restoreMessage == nil ? "Restore Defaults" : "Restore Defaults…") {
                    if restoreMessage == nil { restoreDefaults() } else { confirmingRestore = true }
                }
                .confirmationDialog("Restore defaults?", isPresented: $confirmingRestore) {
                    Button("Restore Defaults", action: restoreDefaults)
                } message: {
                    Text(restoreMessage ?? "")
                }
            }
            Spacer()
            if let advanced { Button("Advanced…", action: advanced) }
        }
        .padding(.top, 4)
    }
}

/// What an `AdvancedSheet` spends on its title, its buttons row and their padding, so the form
/// and this chrome together fit the height `LazyPane.fitted` allows.
private let sheetChromeHeight: CGFloat = 160

/// A pane's Advanced… sheet: a title, a grouped form, and Done as the default button, with an
/// optional button at the bottom-leading edge (General's Reset All Settings…). A sheet never opens
/// another sheet: anything that needs more room inside it is a disclosure (docs/ui-design.md).
struct AdvancedSheet<Content: View, Leading: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top)
            Form {
                SheetBanners()
                content
            }
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
                // As tall as its rows, up to what the screen leaves, then it scrolls. Proposed the
                // parent window's height instead, a long sheet over a short pane (one app in Apps)
                // squeezed its form to nothing.
                .frame(maxHeight: Self.maxFormHeight)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                leading
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: SettingsWindowController.sheetWidth)
    }

    /// The screen's height less the window's toolbar and the sheet's title and buttons.
    private static var maxFormHeight: CGFloat {
        LazyPane.fitted(NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)).height - sheetChromeHeight
    }
}

extension AdvancedSheet where Leading == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, leading: { EmptyView() })
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
