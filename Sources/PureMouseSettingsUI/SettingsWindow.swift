import AppKit
import PureMouseAppSupport
import SwiftUI

/// The Settings window: native toolbar tabs (`NSTabViewController`, `.toolbar` style) over
/// SwiftUI grouped forms. The helper shows one for its whole life, and quits when it closes
/// (`didClose`).
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let width: CGFloat = 600
    /// The most content height a pane may take, strip and form together (and the height the
    /// default views fit in, docs/ui-design.md). A taller pane scrolls. The one place the number
    /// lives: `LazyPane.maxHeight` and `PaneForm` read it.
    nonisolated static let maxContentHeight: CGFloat = 600
    /// An Advanced… sheet sits inside the window's edges, as System Settings' sheets do.
    static let sheetWidth: CGFloat = width - 100
    private static let tabKey = "SettingsTab"
    private static let segmentKey = "SettingsSegment"
    private static let positionKey = "SettingsWindowTopLeft"

    private let context: SettingsContext
    private let defaults: UserDefaults
    private let model: AppModel
    private let tabs = SettingsTabs()
    /// Runs once the window has closed, unless it was shown again meanwhile.
    public var didClose: () -> Void = {}

    public convenience init(model: AppModel) {
        self.init(model: model, defaults: .standard)
    }

    init(model: AppModel, defaults: UserDefaults) {
        self.model = model
        let context = SettingsContext()
        context.tabs = tabs
        self.context = context
        self.defaults = defaults
        let saved = SettingsSelection.remembered(tab: defaults.string(forKey: Self.tabKey),
                                                 segment: defaults.string(forKey: Self.segmentKey))
        tabs.selectSegment(saved.segment)
        tabs.tabStyle = .toolbar
        // No transition of its own: the page change is one transition with the window frame (`PaneTransition`).
        tabs.transitionOptions = []
        for tab in SettingsTab.shown {
            let lazy = LazyPane { [tabs] in Self.content(for: tab, model: model, context: context, tabs: tabs) }
            lazy.title = tab.title
            let item = NSTabViewItem(viewController: lazy)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        // No frame autosave: it restores the size as well as the position, and a stale size is what
        // the window would then be fitted from. The position alone is kept (`windowDidMove`).
        super.init(window: window)
        window.delegate = self
        tabs.didSelect = { defaults.set($0.rawValue, forKey: Self.tabKey) }
        tabs.didSelectSegment = { defaults.set($0.rawValue, forKey: Self.segmentKey) }
        // Find by Pressing belongs to Mouse › Buttons, so leaving Mouse ends one under way.
        tabs.didLeaveMouse = { [weak model] in model?.cancelCapture() }
        // Titled before the first pane loads, so "Untitled" never shows.
        window.title = saved.tab.title
        tabs.open(.tab(saved.tab))
        #if DEBUG
        // For screenshots: edit this mouse's settings (`PUREMOUSE_DEV_MOUSE=<device key>`).
        if let key = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_MOUSE"] { model.selectMouse(key) }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A tab's content, built the first time the tab shows (`LazyPane`). Mouse is a header strip
    /// over its segments, each built the first time it shows (`MouseTab`).
    private static func content(for tab: SettingsTab, model: AppModel, context: SettingsContext,
                                tabs: SettingsTabs) -> NSViewController {
        func host(_ view: some View) -> NSViewController {
            hosting(view, model: model, context: context)
        }
        switch tab {
        case .general: return host(GeneralPane())
        case .apps: return host(AppsPane())
        case .about: return host(AboutPane())
        case .mouse:
            let mouse = MouseTab(segment: tabs.segment) { selection in
                let header = NSHostingView(rootView: MouseHeader(selection: selection).frame(width: width).environment(model)
                    .environment(\.settings, context))
                header.sizingOptions = [.intrinsicContentSize]
                return header
            } make: { segment in
                switch segment {
                case .buttons: host(MouseSegmentPane { ButtonsPane() })
                case .scrolling: host(MouseSegmentPane { ScrollingPane() })
                case .pointer: host(MouseSegmentPane { PointerPane() })
                }
            }
            mouse.didSelect = { [weak tabs] in tabs?.selectSegment($0) }
            mouse.transition = { [weak tabs] swap in
                if let tabs { tabs.transition(swap) } else { swap() }
            }
            mouse.willLeaveButtons = { [weak model] in
                model?.cancelCapture()
                context.card.select(nil)
            }
            tabs.mouse = mouse
            return mouse
        }
    }

    /// A pane's SwiftUI host at the window's width, sized to its content so the window fits it.
    private static func hosting(_ view: some View, model: AppModel, context: SettingsContext) -> NSViewController {
        PaneHost(view.environment(model).environment(\.settings, context))
    }

    public func show(_ request: ShowRequest?) {
        // Someone is looking: let the daemon check what it only learns by looking (Logi Options+).
        model.askDaemonToRecheck()
        if let request { model.select(for: request) }
        // The tab and an app's page change as one transition (none while the window is hidden).
        tabs.transition { [context, tabs] in
            if let pane = request?.pane { tabs.open(pane) }
            if let app = request?.app { context.app = app }
        }
        guard let window else { return }
        if !window.isVisible, !restorePosition(of: window) { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [context] in
            window.makeFirstResponder(nil)
            if let sheet = request?.sheet { context.sheet = sheet }
        }
    }

    /// Puts the window's top-left corner where it was last left, if that is still on a screen. Only
    /// the position: the size comes from the pane.
    func restorePosition(of window: NSWindow) -> Bool {
        guard let saved = defaults.string(forKey: Self.positionKey) else { return false }
        let point = NSPointFromString(saved)
        let onScreen = NSScreen.screens.contains { screen in
            let frame = screen.visibleFrame
            return point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
        }
        guard onScreen else { return false }
        window.setFrameTopLeftPoint(point)
        return true
    }

    /// The window's undo manager is the model's, so Edit › Undo and ⌘Z step through settings changes,
    /// except while any text is being edited: a field editor or a text view (TextEditor, NSTextView)
    /// keeps its own (the window's default one), so ⌘Z undoes typing first. The model's manager
    /// groups by hand (`groupsByEvent` off), and typing registered on it outside a group raises
    /// "must begin a group". None while the config is read-only: its steps would do nothing.
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if window.firstResponder is NSText { return nil }
        if model.readOnly { return nil }
        return model.undoManager
    }

    public func windowDidMove(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        defaults.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)), forKey: Self.positionKey)
    }

    public func windowWillClose(_ notification: Notification) {
        tabs.pageTransition.cancel()
        // Let AppKit finish closing first. A request to show Settings in that gap (the menu bar app
        // rings the doorbell) keeps the window, so the helper stays.
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.isVisible != true else { return }
            didClose()
        }
    }
}

/// Fits the window to each pane's height, keeping its top edge still, and remembers the pane. Its
/// `PaneTransition` is the one thing that moves the window frame.
@MainActor
final class SettingsTabs: NSTabViewController {
    var didSelect: (SettingsTab) -> Void = { _ in }
    var didSelectSegment: (MouseSegment) -> Void = { _ in }
    /// Called when another tab replaces Mouse, whichever way the change came.
    var didLeaveMouse: () -> Void = {}
    private var shownTab: SettingsTab?
    /// The Mouse tab's segment, kept while another tab shows and used when Mouse is first built.
    private(set) var segment: MouseSegment = .buttons
    /// The Mouse tab, once built.
    weak var mouse: MouseTab?
    /// The window frame's one owner: page changes and in-place height changes go through it.
    private(set) lazy var pageTransition = PaneTransition(host: view) { [weak self] in
        self?.fittedFrame()
    } container: { [weak self] in
        self?.tabView
    }

    /// The selected tab's item; nil while nothing is selected (the index is -1).
    private var selectedItem: NSTabViewItem? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex] : nil
    }

    var selectedTab: SettingsTab? {
        (selectedItem?.identifier as? String).flatMap(SettingsTab.init)
    }

    /// Shows Mouse on this segment, now if Mouse is built, else when it is.
    func selectSegment(_ segment: MouseSegment) {
        if segment != self.segment {
            self.segment = segment
            didSelectSegment(segment)
        }
        mouse?.select(segment)
    }

    /// Shows a tab, or Mouse on a segment, as one transition.
    func open(_ pane: SettingsPane) {
        let next = SettingsSelection(tab: selectedTab ?? .mouse, segment: segment).opening(pane)
        transition {
            selectSegment(next.segment)
            if let index = SettingsTab.shown.firstIndex(of: next.tab) { selectedTabViewItemIndex = index }
        }
    }

    /// Makes a change to what the window shows (a tab, a segment, an app's page) as one transition:
    /// the content cross-fades as the frame moves to the new height (`PaneTransition`).
    func transition(_ change: () -> Void) {
        pageTransition.change(change)
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        // A toolbar click arrives here without `open`: the change starts before the old pane goes.
        pageTransition.begin()
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) {
            // The controller moves its index before telling us, so the tab left is the one last shown.
            if shownTab == .mouse, tab != .mouse { didLeaveMouse() }
            shownTab = tab
            didSelect(tab)
        }
        pageTransition.end()
        // No field or button starts focused: Tab still reaches them.
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        // Not passed to super: the window frame has one owner (`PaneTransition`).
        guard let selected = selectedItem?.viewController, viewController === selected else { return }
        pageTransition.fit()
    }

    /// Fits the window to the current pane after its content changed height. The nested hosting
    /// controller's size follows its content, but it never tells its parent, so this passes it
    /// up (`SettingsContext.refit()`: the Apps list growing, a disclosure, a notice).
    func refit() {
        pageTransition.fit()
    }

    /// The window frame that fits the current pane, its top edge where it is now; nil when there
    /// is no window or nothing to measure. The pane is measured now, not read from
    /// `preferredContentSize`, which is only as fresh as its last layout (stale or zero before the
    /// first), and capped to the screen the window is on.
    private func fittedFrame() -> NSRect? {
        guard let window = view.window, let pane = selectedItem?.viewController else { return nil }
        (pane.children.first as? MouseTab)?.fit()
        let size = pane.measuredSize(maxHeight: LazyPane.maxHeight(on: window.screen))
        guard size.height.isFinite, size.height > 0 else { return nil }
        if pane.preferredContentSize != size { pane.preferredContentSize = size }
        let contentRect = NSRect(x: 0, y: 0, width: SettingsWindowController.width, height: size.height)
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        return frame
    }
}

/// A tab's placeholder: builds the pane's SwiftUI host the first time the tab is shown, so panes
/// never visited cost nothing, and passes its preferred size up to the tabs.
@MainActor
final class LazyPane: NSViewController, IdealSized {
    private let make: () -> NSViewController

    init(_ make: @escaping () -> NSViewController) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = make()
        addChild(content)
        view = content.view
        preferredContentSize = content.measuredSize(maxHeight: Self.maxHeight(on: nil))
    }

    func idealSize(maxHeight: CGFloat) -> NSSize {
        children.first?.measuredSize(maxHeight: min(maxHeight, Self.maxHeight(on: view.window?.screen))) ?? preferredContentSize
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        preferredContentSize = Self.fitted(viewController.preferredContentSize, on: view.window?.screen)
    }

    /// The most content height a pane gets: `SettingsWindowController.maxContentHeight`, or less
    /// where the screen (the window's, else the main one) leaves less room for the window's title
    /// and toolbar.
    static func maxHeight(on screen: NSScreen?) -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(SettingsWindowController.maxContentHeight, visible - 80)
    }

    /// A pane's size, no taller than `maxHeight` (a long Apps list scrolls instead). The tab
    /// controller sizes the window from this itself, so capping only in `fitWindow` is not enough.
    static func fitted(_ size: NSSize, on screen: NSScreen? = nil) -> NSSize {
        NSSize(width: size.width, height: min(size.height, maxHeight(on: screen)))
    }
}

extension NSApplication {
    /// Quits even with a sheet open. AppKit ignores `terminate(_:)` while a window has a sheet
    /// attached, so a quit from outside (the menu bar app's Quit PureMouse, SIGTERM, a capture)
    /// would leave the helper running. Edits are already saved as they are made, and
    /// `applicationWillTerminate` flushes the rest.
    ///
    /// Ending the sheets is not always enough: a SwiftUI sheet whose state still says it is shown
    /// is attached again while `terminate(_:)` runs, which then returns without quitting (seen in
    /// the bundled helper with a sheet open). So when it returns, finish the quit as it
    /// would have: announce `willTerminate` (the delegate saves) and exit.
    public func terminateClosingSheets() {
        for window in windows {
            for sheet in window.sheets.reversed() { window.endSheet(sheet) }
        }
        terminate(nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: self)
        exit(0)
    }
}
