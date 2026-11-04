import PureMouseAppSupport
import SwiftUI

private struct SettingsKey: EnvironmentKey {
    static let defaultValue: SettingsContext? = nil
}

extension EnvironmentValues {
    var settings: SettingsContext? {
        get { self[SettingsKey.self] }
        set { self[SettingsKey.self] = newValue }
    }
}

/// A pane that can say how tall it wants to be right now. A controller's `preferredContentSize` is
/// only as fresh as its last layout pass, which a window sized on first show or on a tab change
/// reads too early (stale, zero, or an unbounded ideal), so the window asks the pane instead.
@MainActor
protocol IdealSized: NSViewController {
    /// The size the pane wants, no taller than `maxHeight`.
    func idealSize(maxHeight: CGFloat) -> NSSize
}

extension NSViewController {
    /// What this pane wants now: its own answer if it can give one, else its `preferredContentSize`
    /// (a plain controller has no other), no taller than `maxHeight` either way.
    func measuredSize(maxHeight: CGFloat) -> NSSize {
        let size = (self as? IdealSized)?.idealSize(maxHeight: maxHeight) ?? preferredContentSize
        return NSSize(width: size.width, height: min(size.height, maxHeight))
    }
}

private struct PaneMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = SettingsWindowController.maxContentHeight
}

extension EnvironmentValues {
    /// The most height a pane's form may take (`PaneForm`): the window's content cap, less what
    /// the pane's host keeps above it (the Mouse tab's strip).
    var paneMaxHeight: CGFloat {
        get { self[PaneMaxHeightKey.self] }
        set { self[PaneMaxHeightKey.self] = newValue }
    }
}

/// A pane's SwiftUI view at the window's width.
struct PaneRoot<Content: View>: View {
    let content: Content
    let maxHeight: CGFloat

    var body: some View {
        content
            .frame(width: SettingsWindowController.width)
            .environment(\.paneMaxHeight, maxHeight)
    }
}

/// A pane's SwiftUI host. It reports its ideal size by asking SwiftUI (`sizeThatFits`), which is
/// exact at once, instead of waiting for a layout pass to update `preferredContentSize`.
@MainActor
final class PaneHost<Content: View>: NSHostingController<PaneRoot<Content>>, IdealSized {
    private let content: Content

    init(_ content: Content) {
        self.content = content
        super.init(rootView: PaneRoot(content: content, maxHeight: SettingsWindowController.maxContentHeight))
        sizingOptions = .preferredContentSize
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    func idealSize(maxHeight: CGFloat) -> NSSize {
        // The limit travels in the root view, so changing it is a new root, applied before the measure.
        if rootView.maxHeight != maxHeight { rootView = PaneRoot(content: content, maxHeight: maxHeight) }
        return sizeThatFits(in: NSSize(width: SettingsWindowController.width, height: maxHeight))
    }
}

/// A grouped form as tall as its rows, up to the pane's limit (`paneMaxHeight`, 600 pt of content),
/// then it scrolls. Its height is bounded here, not left to its content: proposed no limit, a form
/// has now and then measured as tall as the screen allows (a 2400 pt blank window), and the window
/// sized itself to that.
struct PaneForm<Content: View>: View {
    @Environment(\.paneMaxHeight) private var maxHeight
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            // Looks the same, but leaves the window's own background (tinted by the desktop)
            // showing, so a page change's snapshot matches the page (`PaneTransition`).
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}
