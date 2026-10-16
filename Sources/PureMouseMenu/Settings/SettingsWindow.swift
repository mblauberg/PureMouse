import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general, buttons, scrolling, pointer, apps, about

    var title: String {
        switch self {
        case .general: "General"
        case .buttons: "Buttons"
        case .scrolling: "Scrolling"
        case .pointer: "Pointer"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    /// SF Symbols available on macOS 14.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .buttons: "computermouse"
        case .scrolling: "arrow.up.and.down"
        case .pointer: "cursorarrow"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

/// The Settings window: native toolbar tabs (`NSTabViewController`, `.toolbar` style) over
/// SwiftUI grouped forms. Created when first shown and released when closed.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let width: CGFloat = 600
    private static let paneKey = "SettingsPane"

    private let app: AppController
    private let tabs = SettingsTabs()

    init(model: AppModel, app: AppController) {
        self.app = app
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in SettingsPane.allCases {
            let lazy = LazyPane {
                let host = NSHostingController(rootView: PaneHost(pane: pane, app: app).environment(model))
                host.sizingOptions = .preferredContentSize
                return host
            }
            lazy.title = pane.title
            let item = NSTabViewItem(viewController: lazy)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
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
        tabs.didSelect = { pane in UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
        let saved = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .buttons
        // Titled before the first pane loads, so "Untitled" never shows.
        window.title = saved.title
        select(saved)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane: SettingsPane?) {
        if let pane { select(pane) }
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    private func select(_ pane: SettingsPane) {
        if let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Let AppKit finish closing before the controller and its views go.
        DispatchQueue.main.async { [app] in app.settingsDidClose() }
    }
}

/// Fits the window to each pane's height, keeping its top edge still, and remembers the pane.
@MainActor
final class SettingsTabs: NSTabViewController {
    var didSelect: (SettingsPane) -> Void = { _ in }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) { didSelect(pane) }
        fitWindow(animated: view.window?.isVisible == true)
        // No field or button starts focused: Tab still reaches them.
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabViewItems[selectedTabViewItemIndex].viewController else { return }
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// Fits the window to the current pane after its content changed height. The nested hosting
    /// controller's size follows its content, but it never tells its parent, so this passes it
    /// up (the Apps pane calls it when it opens an app or goes back).
    func refit() {
        guard let pane = tabViewItems[selectedTabViewItemIndex].viewController,
              let host = pane.children.first else { return }
        pane.preferredContentSize = host.preferredContentSize
    }

    private func fitWindow(animated: Bool) {
        guard let window = view.window,
              let content = tabViewItems[selectedTabViewItemIndex].viewController else { return }
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
        preferredContentSize = content.preferredContentSize
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        preferredContentSize = viewController.preferredContentSize
    }
}
