#if DEBUG
import AppKit
import PureMouseAppSupport

/// Development only, so screenshots can be taken without clicking: `PUREMOUSE_DEV_PANE=<pane>`
/// opens Settings on a tab (`general`, `mouse`, `apps`, `about`) or a Mouse segment (`buttons`,
/// `scrolling`, `pointer`), and `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system
/// appearance. On Mouse › Buttons, `PUREMOUSE_DEV_PICKER=<button>` opens a button's action picker
/// and `PUREMOUSE_DEV_SHORTCUT=<button>` its shortcut sheet. On the Apps pane,
/// `PUREMOUSE_DEV_APP=<bundle id>` opens (or adds) that app's page, `PUREMOUSE_DEV_APP_SEGMENT=
/// buttons|scrolling` shows one of its segments, and `PUREMOUSE_DEV_SHORTCUT=<button>` opens that
/// button's shortcut editor sheet over it.
/// `PUREMOUSE_DEV_SHEET=<name>` opens a sheet: `presets` (Mouse › Pointer) through a `ShowRequest`,
/// or a sheet on the pane shown (`DevSheet`).
/// `PUREMOUSE_DEV_MOUSE=<device key>` edits that mouse's settings, as the Mouse pop-up would
/// (`SettingsWindowController.init`); `PUREMOUSE_DEV_OTHERS=1` opens Buttons' "Other controls".
/// On Buttons' device card, `PUREMOUSE_DEV_HOVER=<part>` (`middle`, `top`, `forward`, `back`, `thumbWheel`,
/// `thumbRest`) shows that part hovered, `PUREMOUSE_DEV_BUTTON=<button>` selects a button as a click
/// would and `PUREMOUSE_DEV_FOUND=<button>` marks the row Find by Pressing found. On Scrolling,
/// `PUREMOUSE_DEV_ARRIVAL=mainWheel|thumbWheel` arrives as the card sends one there, and
/// `PUREMOUSE_DEV_ARRIVAL_HOLD=1` keeps its outline from fading.
/// `PUREMOUSE_DEV_CAPTURE=<file.png>` saves the windows to that file and quits (`DevCapture`).
/// `PUREMOUSE_DEV_AX_DUMP=1` prints every control's accessibility role, label and size for each
/// tab and segment, or for what the hooks above open, and quits (`DevAXDump`).
@MainActor
public enum DevHooks {
    /// The sheet to open on `pane`, only when `PUREMOUSE_DEV_PANE` names it: Mouse builds more
    /// than the segment shown, so a check without the pane opened Scrolling's sheet over Buttons.
    static func sheet(on pane: String) -> DevSheet? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PUREMOUSE_DEV_PANE"] == pane else { return nil }
        return environment["PUREMOUSE_DEV_SHEET"].flatMap(DevSheet.init(rawValue:))
    }

    public static func run(show: @escaping (ShowRequest) -> Void) {
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
        DevCapture.schedule(environment)
        DevAXDump.schedule(environment, show: show)
    }
}

/// A sheet `PUREMOUSE_DEV_SHEET` opens: one case per sheet; a pane checks `DevHooks.sheet(on:)` as
/// it appears.
enum DevSheet: String {
    /// The pane's Advanced… sheet (General, Mouse › Buttons, Mouse › Scrolling).
    case advanced
}
#endif
