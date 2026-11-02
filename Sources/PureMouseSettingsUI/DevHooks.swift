#if DEBUG
import AppKit
import PureMouseAppSupport

/// Development only, so screenshots can be taken without clicking: `PUREMOUSE_DEV_PANE=<pane>`
/// opens Settings on a tab (`general`, `mouse`, `apps`, `about`) or a Mouse segment (`buttons`,
/// `scrolling`, `pointer`), and `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system
/// appearance. On Mouse › Buttons, `PUREMOUSE_DEV_PICKER=<button>` opens a button's action picker
/// and `PUREMOUSE_DEV_SHORTCUT=<button>` its shortcut sheet. On the Apps pane,
/// `PUREMOUSE_DEV_APP=<bundle id>` opens (or adds) that app's sheet, and with it
/// `PUREMOUSE_DEV_SHORTCUT=<button>` opens that button's shortcut editor popover.
/// `PUREMOUSE_DEV_SHEET=<name>` opens a sheet: `presets` (Mouse › Pointer) through a `ShowRequest`,
/// or a sheet on the pane shown (`DevSheet`).
@MainActor
public enum DevHooks {
    static var sheet: DevSheet? {
        ProcessInfo.processInfo.environment["PUREMOUSE_DEV_SHEET"].flatMap(DevSheet.init(rawValue:))
    }

    public static func run(show: (ShowRequest) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        // The menu bar app's `DevHooks` reads the same variable the same way.
        switch environment["PUREMOUSE_DEV_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let pane = environment["PUREMOUSE_DEV_PANE"].flatMap(SettingsPane.init(rawValue:)) {
            show(ShowRequest(pane: pane))
            // A launch from a terminal is not allowed to take focus cooperatively.
            NSApp.activate(ignoringOtherApps: true)
        }
        switch environment["PUREMOUSE_DEV_SHEET"] {
        case "presets": show(ShowRequest(sheet: .presets))
        default: break
        }
    }
}

/// A sheet `PUREMOUSE_DEV_SHEET` opens: one case per sheet; a pane checks `DevHooks.sheet` as it
/// appears.
enum DevSheet: String {
    /// The pane's Advanced… sheet (Mouse › Buttons, Mouse › Scrolling).
    case advanced
}
#endif
