#if DEBUG
import AppKit
import PureMouseAppSupport

/// Development only, so screenshots can be taken without clicking: `PUREMOUSE_DEV_PANE=<pane>`
/// opens Settings on a pane and `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system
/// appearance. On the Buttons pane, `PUREMOUSE_DEV_PICKER=<button>` opens a button's action picker
/// and `PUREMOUSE_DEV_SHORTCUT=<button>` its shortcut sheet. On the Apps pane,
/// `PUREMOUSE_DEV_APP=<bundle id>` opens (or adds) that app's settings.
@MainActor
public enum DevHooks {
    public static func run(show: (SettingsPane) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        switch environment["PUREMOUSE_DEV_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let pane = environment["PUREMOUSE_DEV_PANE"].flatMap(SettingsPane.init) {
            show(pane)
            // A launch from a terminal is not allowed to take focus cooperatively.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
