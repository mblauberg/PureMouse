#if DEBUG
import AppKit

/// Development only: `PUREMOUSE_DEV_PANE=<pane>` opens Settings on a pane and
/// `PUREMOUSE_DEV_MENU=1` opens the menu, so screenshots can be taken without clicking.
/// `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system appearance.
/// On the Buttons pane, `PUREMOUSE_DEV_PICKER=<button>` opens a button's action picker and
/// `PUREMOUSE_DEV_SHORTCUT=<button>` its shortcut sheet.
@MainActor
enum DevHooks {
    static func run(app: AppController) {
        let environment = ProcessInfo.processInfo.environment
        switch environment["PUREMOUSE_DEV_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let pane = environment["PUREMOUSE_DEV_PANE"].flatMap(SettingsPane.init) {
            app.showSettings(pane: pane)
            // A launch from a terminal is not allowed to take focus cooperatively.
            NSApp.activate(ignoringOtherApps: true)
        }
        if environment["PUREMOUSE_DEV_MENU"] != nil {
            // The menu's glass shows what is under it: a plain desktop, not whatever is on screen.
            backdrop = plainBackdrop()
            // A status menu follows the menu bar's appearance, not the app's.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.openMenuForTesting(appearance: NSApp.appearance) }
        }
    }

    private static var backdrop: NSWindow?

    private static func plainBackdrop() -> NSWindow? {
        guard let screen = NSScreen.main else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let dark = (NSApp.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        window.backgroundColor = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }
}
#endif
