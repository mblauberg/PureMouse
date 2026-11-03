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
    /// The scope has its own value: "Set for this mouse." and its button take the help's place, on
    /// the same line (`View.overridable(_:help:)` makes the help the row's tooltip).
    var note: InheritedOverride?
    /// What VoiceOver calls the row in the note's button, where the title alone is ambiguous
    /// (the same direction under two buttons).
    var spokenTitle: String?
    /// The help stays under the title beside a note: it says something the control can't (Feel's
    /// "Custom. Adjust in Advanced." when no preset is selected).
    var keepsHelp = false

    init(_ title: String, help: String? = nil, mouseDefault: Bool = false,
         availability: ControlAvailability = .available, note: InheritedOverride? = nil, spokenTitle: String? = nil,
         keepsHelp: Bool = false) {
        self.keepsHelp = keepsHelp
        self.spokenTitle = spokenTitle
        self.title = title
        self.help = help
        self.mouseDefault = mouseDefault
        self.availability = availability
        self.note = note
    }

    static let mouseDefaultCaption = "Using the mouse's own setting."

    /// The caption sentences that apply. One stands as written; two or more run together as
    /// separate sentences, each with its full stop, so a help without one and "Not supported by
    /// this mouse." do not merge.
    static func caption(_ sentences: [String?]) -> String? {
        let parts = sentences.compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        guard parts.count > 1 else { return parts.first }
        let ends: Set<Character> = [".", "!", "?", "…"]
        return parts.map { part in part.last.map { ends.contains($0) } == true ? part : part + "." }.joined(separator: " ")
    }

    /// The caption under the title. A changed row's help is its tooltip, so it is not here (unless `keepsHelp`).
    var captionText: String? {
        Self.caption([note == nil || keepsHelp ? help : nil, mouseDefault ? Self.mouseDefaultCaption : nil, availability.caption])
    }

    var body: some View {
        Text(title)
        if let captionText { Text(captionText) }
        if let note { OverrideLine(note: note, subject: spokenTitle ?? title) }
    }
}

/// A pop-up's closed face as the form's own pop-up menus draw it: the value, then the up/down
/// chevrons. One drawing for every pop-up in Settings (`PopUpMenu`, `ActionButton`), so the
/// action rows on Buttons, Scrolling and an app's page read alike.
struct PopUpLabel: View {
    let text: String

    var body: some View {
        // One `Text` with the chevrons set in it, not a stack: a `Menu` takes a label apart into
        // title and image and draws the image first, which put the chevrons before the value on every
        // pop-up that is a `Menu` (`PopUpMenu`). Primary for the value, as the form's own pop-ups
        // draw it (a `LabeledContent` makes it secondary). Cut in the middle when it is too long, so
        // the chevrons stay.
        (Text(text).foregroundStyle(.primary)
            + Text(" ")
            + Text(Image(systemName: "chevron.up.chevron.down")).font(.footnote).foregroundStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(text)
    }
}

/// A standard pop-up for a short list of choices: a `Menu` drawn as a push button around
/// `PopUpLabel`, the same bezel as `ActionButton`. A bare `Picker`
/// in a grouped form can draw as a borderless pull-down with a circled chevron instead.
struct PopUpMenu<Content: View>: View {
    let text: String
    /// Nil: the width its text needs. A width: the width its text needs up to that, as a macOS
    /// pop-up draws, then it takes what room it is given and cuts the text with an ellipsis. A
    /// `Menu` in a stack otherwise takes all the width it is offered, with its text at the leading
    /// edge and dead space after it.
    var maxWidth: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        let menu = Menu {
            content
        } label: {
            PopUpLabel(text: text)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        if let maxWidth {
            // The first that fits the width on offer (the cap, or the room if that is less); the
            // second, which fills it, is for text too long for it.
            ViewThatFits(in: .horizontal) {
                menu.fixedSize()
                menu
            }
            // Leading, so a pop-up narrower than the room it is offered sits at the edge, not in the middle.
            .frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            menu.fixedSize()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A slider with its words under each end, as System Settings draws them (Slow … Fast), and
/// its value on the right. Every slider is one width, so the tracks of a pane's rows line up
/// whatever their labels and readouts.
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
    var showsReadout = true
    var availability = ControlAvailability.available
    /// The key is absent and the mouse keeps its own setting (`RowLabel.mouseDefault`).
    var mouseDefault = false
    /// On a mouse or in an app: whether the value is its own rather than the wider scope's.
    var standing = RowStanding.none
    /// In an app: said to VoiceOver in place of the number while the mice the app leaves the value
    /// to differ, since the slider's position is then only the first mouse's ("Varies by Mouse").
    /// The readout says the short "Varies", which fits the room every slider row shares, so the
    /// track stays where it is on Mouse › Scrolling.
    var variesText: String?
    private var note: InheritedOverride? { standing.note }

    var body: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                EndLabeledSlider(title: spokenTitle ?? title, value: $value, range: range, low: low, high: high)
                    .accessibilityValue(standing.spoken(variesText ?? format(value)))
                    .frame(width: 200)
                // The readout takes the room of the widest value it can show, hidden, so the
                // slider does not shift as the digits change, and at least one shared width, so
                // the tracks of rows with short and long readouts ("2.2", "300 ms") line up.
                if showsReadout {
                    ZStack(alignment: .trailing) {
                        Text(format(range.lowerBound)).hidden()
                        Text(format(range.upperBound)).hidden()
                        Text(variesText == nil ? format(value) : Applied<Double>.variesReadout)
                    }
                    .frame(minWidth: 56, alignment: .trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }
        } label: {
            RowLabel(title, help: help, mouseDefault: mouseDefault, availability: availability, note: note,
                     spokenTitle: spokenTitle)
        }
        .overridable(note, help: help)
    }
}

/// A plain slider with its words under its ends, in caption type, as System Settings draws
/// them: `minimumValueLabel` and `maximumValueLabel` would put them beside the track, making each
/// row's track a different length. The slider speaks its title; VoiceOver reads the value, not
/// the end words. No `step:`: macOS would draw a tick per step, so callers snap in their
/// binding instead.
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
            // No words when there are none to say (Pointer Speed before the mouse has reported
            // its range).
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
    /// A binding to a numeric key as it applies in `target`'s scope, showing `fallback` when absent.
    /// Writes are debounced and land in that scope only.
    func number(_ path: [String], default fallback: Double, step: Double, in target: ScopeTarget) -> Binding<Double> {
        Binding {
            self.config.number(path, in: target.scope, default: fallback)
        } set: {
            self.set(Format.snap($0, step: step), at: path, in: target, debounce: true)
        }
    }

    /// Where a row for `paths` stands in `target`'s scope: on a mouse, own while it holds any of them
    /// (`reset` gives them back to All Mice); nothing wider for All Mice.
    func standing(of paths: [[String]], in target: ScopeTarget) -> RowStanding {
        RowStanding.of(paths, in: config, scope: target.scope) { [self] in
            update(in: target) { $0.removeOverrides(paths, in: target.scope) }
        }
    }

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
        // A section's footer is set in by the form's row padding on both sides, so its buttons sat
        // 10 pt inside the grouped boxes, where the header strip's Find by Pressing… ends flush.
        .padding(.horizontal, -Self.formInset)
        .padding(.top, 4)
    }

    /// How far the grouped form sets a section footer in from the edge of its boxes.
    private static let formInset: CGFloat = 10
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
            // In line with the grouped form's content box, not the sheet's edge.
            .padding(.horizontal, Self.contentInset)
            .padding(.bottom)
        }
        .frame(width: SettingsWindowController.sheetWidth)
    }

    /// How far a grouped form's sections sit in from the sheet's edge.
    private static var contentInset: CGFloat { 20 }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var help: String?
    /// The scope has its own value: its caption line follows the help (`RowLabel.note`).
    var note: InheritedOverride?
    /// What VoiceOver calls the disclosure where the title alone names another control in the row
    /// (a gesture button's action pop-up).
    var spokenTitle: String?
    @Binding var isExpanded: Bool

    var body: some View {
        // The note's button sits beside the disclosure button, not inside it: a button can't hold one.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DisclosureMotion.animates(reduceMotion: reduceMotion) ? .easeInOut(duration: 0.2) : nil) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let help, note == nil { Text(help).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                // A line of text is 16 pt tall; the padding takes the hit target to the 20 pt minimum.
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Preserve the separate form rows visually while exposing a native disclosure to AX.
            .accessibilityRepresentation {
                DisclosureGroup(isExpanded: $isExpanded) {} label: { Text(spokenTitle ?? title) }
            }
            if let note { OverrideLine(note: note, subject: spokenTitle ?? title).disclosedRow() }
        }
    }
}

extension View {
    /// Indents a disclosed child row past its parent's triangle.
    func disclosedRow() -> some View { padding(.leading, 22) }
}
