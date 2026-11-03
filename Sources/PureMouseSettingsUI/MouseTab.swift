import AppKit
import PureMouseAppSupport
import SwiftUI

/// The Mouse tab's selected segment, which its header strip shows and changes.
@MainActor @Observable
final class MouseSelection {
    fileprivate(set) var segment: MouseSegment
    /// Asks the tab to show a segment.
    @ObservationIgnored fileprivate var choose: (MouseSegment) -> Void = { _ in }

    fileprivate init(_ segment: MouseSegment) { self.segment = segment }

    func select(_ segment: MouseSegment) { choose(segment) }
}

/// The Mouse tab: a fixed header strip over the selected segment's pane. Each segment's pane is
/// built the first time it shows and kept, as `LazyPane` does for tabs, so segments never visited
/// cost nothing. Its preferred size is the strip's height plus the pane's, which `fit()` brings up
/// to date; the tabs call it when they refit.
@MainActor
final class MouseTab: NSViewController, IdealSized {
    let selection: MouseSelection
    /// Called when the segment changes, after its pane shows, so the window can refit to it.
    var didSelect: (MouseSegment) -> Void = { _ in }
    /// Called as the segment changes away from Buttons, whichever way the change came (the strip
    /// or a request), so Find by Pressing, which belongs to Buttons, ends with it.
    var willLeaveButtons: () -> Void = {}

    private let makeHeader: (MouseSelection) -> NSView
    private let make: (MouseSegment) -> NSViewController
    private var built: [MouseSegment: NSViewController] = [:]
    private var header: NSView?
    private var shown: NSViewController?
    private var shownConstraints: [NSLayoutConstraint] = []

    init(segment: MouseSegment, header: @escaping (MouseSelection) -> NSView,
         make: @escaping (MouseSegment) -> NSViewController) {
        selection = MouseSelection(segment)
        makeHeader = header
        self.make = make
        super.init(nibName: nil, bundle: nil)
        selection.choose = { [weak self] in self?.select($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let header = makeHeader(selection)
        header.translatesAutoresizingMaskIntoConstraints = false
        // When the window is capped below strip plus pane, the pane scrolls; the strip never shrinks.
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        self.header = header
        view = root
        show(selection.segment)
    }

    /// Shows a segment, building its pane on its first visit.
    func select(_ segment: MouseSegment) {
        guard segment != selection.segment else { return }
        if selection.segment == .buttons { willLeaveButtons() }
        selection.segment = segment
        if isViewLoaded { show(segment) }
        didSelect(segment)
    }

    private func show(_ segment: MouseSegment) {
        let pane = built[segment] ?? {
            let pane = make(segment)
            built[segment] = pane
            addChild(pane)
            return pane
        }()
        guard pane !== shown, let header else { return }
        shown?.view.removeFromSuperview()
        NSLayoutConstraint.deactivate(shownConstraints)
        shown = pane
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        shownConstraints = [
            pane.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(shownConstraints)
        fit()
    }

    /// The segments built so far, for tests.
    var builtSegments: Set<MouseSegment> { Set(built.keys) }

    /// Brings the preferred size up to date: the strip, then the pane at its own height.
    func fit() {
        let size = idealSize(maxHeight: LazyPane.maxHeight(on: view.window?.screen))
        if preferredContentSize != size { preferredContentSize = size }
    }

    /// The strip plus the pane, no taller than `maxHeight`: the pane is measured now (not read
    /// from a stale `preferredContentSize`) and given what the strip leaves, so its form scrolls
    /// inside that and the two together never pass the cap.
    func idealSize(maxHeight: CGFloat) -> NSSize {
        guard let shown, let header else { return preferredContentSize }
        let strip = header.fittingSize
        let pane = shown.measuredSize(maxHeight: max(maxHeight - strip.height, 0))
        return NSSize(width: max(pane.width, strip.width), height: min(strip.height + pane.height, maxHeight))
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === shown { fit() }
    }
}

/// The strip above the Mouse tab's groups: the segments, centred, and Find by Pressing… on Buttons.
/// It stays put between segments: same controls, same height.
struct MouseHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    let selection: MouseSelection

    var body: some View {
        // The segments sit in the middle whichever sides are present: each side is a slot that
        // stays in the layout when empty (its Spacer keeps it), and the two share what is left
        // equally, so the pop-up gets the room beside them and cuts a long name with an ellipsis
        // instead of overlapping. The stack's own spacing keeps them apart.
        HStack {
            HStack(spacing: 0) {
                // The leading slot is the mouse pop-up's, with two or more mice (docs/ui-design.md).
                if model.showsMouseMenu { MousePopUp() }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Picker("Mouse settings", selection: Binding(get: { selection.segment }, set: { model.clearCaptureOutcome(); selection.select($0) })) {
                ForEach(MouseSegment.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if selection.segment == .buttons { findByPressing }
            }
            .frame(maxWidth: .infinity)
        }
        // In line with the grouped boxes below, whose form insets them by the same margin.
        .padding(.horizontal, 20)
        .padding(.top)
        // The pop-up and its note come and go with the mice known, which changes the strip's height.
        .onChange(of: model.showsMouseMenu) { settings?.refit() }
        .onChange(of: model.captureOutcome) { _, outcome in
            if let outcome { AccessibilityNotification.Announcement(outcome.message).post() }
        }
    }

    @ViewBuilder private var findByPressing: some View {
        if model.captureListening {
            Button("Cancel") { model.cancelCapture() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel Find by Pressing")
        } else {
            Button("Find by Pressing…") { model.startCapture() }
                .disabled(!model.daemonRunning || model.paused || model.readOnly)
                .help(model.daemonRunning ? "Press a mouse button to find its row" : "PureMouse is off")
        }
    }
}

/// The pop-up that chooses which mouse the panes edit: All Mice, then each known mouse by name. The
/// choice is remembered. The notes are the menu's last lines, the one explanation of how a mouse's
/// rows work ("Settings you don't change follow All Mice.") and that Apps is global; the pop-up's
/// tooltip carries the Apps note: a line under the pop-up would take 15 pt from a strip every segment
/// shares, and Scrolling has 6 pt to spare (docs/ui-design.md, "Fit").
struct MousePopUp: View {
    @Environment(AppModel.self) private var model

    static let appsNote = "Apps are the same for every mouse."
    /// Said once, here: rows that match All Mice carry no mark of it.
    static let followNote = "Settings you don't change follow All Mice."

    private var closedText: String {
        model.selectedMouse?.name ?? InheritedScope.allMice
    }

    var body: some View {
        PopUpMenu(text: closedText, flexible: true) {
            Picker("Mouse", selection: Binding<String?>(get: { model.selectedMouse?.key }, set: { model.selectMouse($0) })) {
                Text(InheritedScope.allMice).tag(nil as String?)
                Divider()
                ForEach(model.knownMice) { Text($0.name).tag($0.key as String?) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Text(Self.followNote)
            Text(Self.appsNote)
        }
        .help(Self.appsNote)
        .accessibilityLabel("Choose mouse")
        .accessibilityValue(model.selectedMouse?.name ?? InheritedScope.allMice)
        .accessibilityHint("\(Self.followNote) \(Self.appsNote)")
    }
}
