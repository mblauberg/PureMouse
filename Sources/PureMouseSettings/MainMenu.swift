import AppKit

/// The helper's menu bar: About and Quit, editing keys for text fields, ⌘W, and Help.
@MainActor
enum MainMenu {
    /// "PureMouse Help": the troubleshooting page.
    static let helpURL = URL(string: "https://github.com/mblauberg/PureMouse/blob/main/docs/troubleshooting.md")!

    /// What the About and Help items do, held for the menu items' target (`NSMenuItem` takes a
    /// target and a selector, not a closure).
    @MainActor
    final class Actions: NSObject {
        let showAbout: @MainActor () -> Void
        let open: @MainActor (URL) -> Void

        init(showAbout: @escaping @MainActor () -> Void, open: @escaping @MainActor (URL) -> Void) {
            self.showAbout = showAbout
            self.open = open
        }

        @objc func about(_ sender: Any?) { showAbout() }
        @objc func help(_ sender: Any?) { open(MainMenu.helpURL) }
    }

    /// `actions` is retained by the menu items' targets only weakly, so the caller keeps it.
    static func make(actions: Actions) -> NSMenu {
        let main = NSMenu()

        // The helper shows as PureMouse (docs/adr/0009-settings-helper-app.md, amendment).
        let appMenu = NSMenu(title: "PureMouse")
        let about = appMenu.addItem(withTitle: "About PureMouse", action: #selector(Actions.about(_:)), keyEquivalent: "")
        about.target = actions
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PureMouse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // Quits Settings only; the menu bar app's Quit PureMouse is the one that stops PureMouse (ADR 9, amendment).
        appMenu.addItem(withTitle: "Quit Settings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        let helpItem = help.addItem(withTitle: "PureMouse Help", action: #selector(Actions.help(_:)), keyEquivalent: "?")
        helpItem.target = actions
        main.addItem(submenu: help)
        NSApp.helpMenu = help
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
