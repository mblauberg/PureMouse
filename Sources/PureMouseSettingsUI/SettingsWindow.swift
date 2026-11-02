import AppKit
import PureMouseAppSupport
import SwiftUI

/// The Settings window: native toolbar tabs (`NSTabViewController`, `.toolbar` style) over
/// SwiftUI grouped forms. The helper shows one for its whole life, and quits when it closes
/// (`didClose`).
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let width: CGFloat = 600
    /// An Advanced… sheet sits inside the window's edges, as System Settings' sheets do.
    static let sheetWidth: CGFloat = width - 100
    private static let tabKey = "SettingsTab"
    private static let segmentKey = "SettingsSegment"

    private let context: SettingsContext
    private let tabs = SettingsTabs()
    /// Runs once the window has closed, unless it was shown again meanwhile.
    public var didClose: () -> Void = {}

    public init(model: AppModel) {
        let context = SettingsContext()
        context.tabs = tabs
        self.context = context
        let defaults = UserDefaults.standard
        let saved = SettingsSelection.remembered(tab: defaults.string(forKey: Self.tabKey),
                                                 segment: defaults.string(forKey: Self.segmentKey))
        tabs.selectSegment(saved.segment)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
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
        window.setFrameAutosaveName("PureMouseSettings")
        super.init(window: window)
        window.delegate = self
        tabs.didSelect = { defaults.set($0.rawValue, forKey: Self.tabKey) }
        tabs.didSelectSegment = { defaults.set($0.rawValue, forKey: Self.segmentKey) }
        // Find by Pressing belongs to Mouse › Buttons, so leaving Mouse ends one under way.
        tabs.didLeaveMouse = { [weak model] in model?.cancelCapture() }
        // Titled before the first pane loads, so "Untitled" never shows.
        window.title = saved.tab.title
        tabs.open(.tab(saved.tab))
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
                let header = NSHostingView(rootView: MouseHeader(selection: selection).frame(width: width).environment(model))
                header.sizingOptions = [.intrinsicContentSize]
                return header
            } make: { segment in
                switch segment {
                case .buttons: host(ButtonsPane())
                case .scrolling: host(ScrollingPane())
                case .pointer: host(PointerPane())
                }
            }
            mouse.didSelect = { [weak tabs] in
                tabs?.selectSegment($0)
                context.refit()
            }
            mouse.willLeaveButtons = { [weak model] in model?.cancelCapture() }
            tabs.mouse = mouse
            return mouse
        }
    }

    /// A pane's SwiftUI host at the window's width, sized to its content so the window fits it.
    private static func hosting(_ view: some View, model: AppModel, context: SettingsContext) -> NSViewController {
        let host = NSHostingController(rootView: view.frame(width: width).environment(model).environment(\.settings, context))
        host.sizingOptions = .preferredContentSize
        return host
    }

    public func show(_ request: ShowRequest?) {
        if let pane = request?.pane { tabs.open(pane) }
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [context] in
            window.makeFirstResponder(nil)
            if let sheet = request?.sheet { context.sheet = sheet }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        // Let AppKit finish closing first. A request to show Settings in that gap (the menu bar app
        // rings the doorbell) keeps the window, so the helper stays.
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.isVisible != true else { return }
            didClose()
        }
    }
}

/// Fits the window to each pane's height, keeping its top edge still, and remembers the pane.
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

    /// Shows a tab, or Mouse on a segment.
    func open(_ pane: SettingsPane) {
        let next = SettingsSelection(tab: selectedTab ?? .mouse, segment: segment).opening(pane)
        selectSegment(next.segment)
        if let index = SettingsTab.shown.firstIndex(of: next.tab) { selectedTabViewItemIndex = index }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) {
            // The controller moves its index before telling us, so the tab left is the one last shown.
            if shownTab == .mouse, tab != .mouse { didLeaveMouse() }
            shownTab = tab
            didSelect(tab)
        }
        fitWindow(animated: view.window?.isVisible == true)
        // No field or button starts focused: Tab still reaches them.
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard let selected = selectedItem?.viewController, viewController === selected else { return }
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// Fits the window to the current pane after its content changed height. The nested hosting
    /// controller's size follows its content, but it never tells its parent, so this passes it
    /// up (the Apps pane calls it when its list grows or shrinks; the Mouse tab when its
    /// segment changes).
    func refit() {
        guard let pane = selectedItem?.viewController,
              let host = pane.children.first else { return }
        (host as? MouseTab)?.fit()
        pane.preferredContentSize = LazyPane.fitted(host.preferredContentSize)
    }

    private func fitWindow(animated: Bool) {
        guard let window = view.window,
              let content = selectedItem?.viewController else { return }
        let size = content.preferredContentSize
        guard size.height > 0 else { return }
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let contentRect = NSRect(x: 0, y: 0, width: SettingsWindowController.width,
                                 height: min(size.height, maxHeight - 80))
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// A tab's placeholder: builds the pane's SwiftUI host the first time the tab is shown, so panes
/// never visited cost nothing, and passes its preferred size up to the tabs.
@MainActor
final class LazyPane: NSViewController {
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
        preferredContentSize = Self.fitted(content.preferredContentSize)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        preferredContentSize = Self.fitted(viewController.preferredContentSize)
    }

    /// A pane's size, no taller than the screen allows (a long Apps list scrolls instead). The tab
    /// controller sizes the window from this itself, so capping only in `fitWindow` is not enough.
    static func fitted(_ size: NSSize) -> NSSize {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        return NSSize(width: size.width, height: min(size.height, maxHeight))
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
    /// the bundled helper with an app's sheet open). So when it returns, finish the quit as it
    /// would have: announce `willTerminate` (the delegate saves) and exit.
    public func terminateClosingSheets(status: Int32 = 0) {
        for window in windows {
            for sheet in window.sheets.reversed() { window.endSheet(sheet) }
        }
        terminate(nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: self)
        exit(status)
    }
}
