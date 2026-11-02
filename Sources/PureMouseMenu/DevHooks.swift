#if DEBUG || DEVHOOKS
import AppKit
import PureMouseKit
import notify

/// Development only: `PUREMOUSE_DEV_PANE=<pane>` opens Settings on a pane and
/// `PUREMOUSE_DEV_MENU=1` opens the menu, so screenshots can be taken without clicking.
/// `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system appearance.
/// On the Buttons pane, `PUREMOUSE_DEV_PICKER=<button>` opens a button's action picker and
/// `PUREMOUSE_DEV_SHORTCUT=<button>` its shortcut sheet. On the Apps pane,
/// `PUREMOUSE_DEV_APP=<bundle id>` opens (or adds) that app's settings.
///
/// A release build has none of this unless it is built with `-DDEVHOOKS` (`scripts/measure-menu.sh`),
/// which compiles in only `Rig`, below.
@MainActor
enum DevHooks {
    static func run(app: AppController) {
        #if DEBUG
        screenshots(app: app)
        #endif
        #if DEVHOOKS
        Rig.start(app: app)
        #endif
    }

    #if DEBUG
    private static func screenshots(app: AppController) {
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
    #endif
}

#if DEVHOOKS
/// The footprint rig's remote control (`scripts/measure-menu.sh`). It acts only when
/// `PUREMOUSE_COMPANION_DIR` is set, and listens on a doorbell named from that directory like the
/// channel's own (`Companion.doorbell`), so it never answers, or rings, an installed app. The
/// script writes `rig-command` as "<number> <verb>" and rings; the answer is the number in
/// `rig-ack` once the verb is done. `rig-ready` lists the doorbells this process listens on.
///
/// Verbs: `menu` opens the menu and closes it again, `settings` and `settings-close` show and close
/// the Settings window, `relief` runs `malloc_zone_pressure_relief`.
@MainActor
private enum Rig {
    private static var token: Int32 = -1

    static func start(app: AppController) {
        guard let directory = ProcessInfo.processInfo.environment["PUREMOUSE_COMPANION_DIR"], !directory.isEmpty else { return }
        let bell = Companion.doorbell("io.github.mblauberg.puremouse.rig")
        notify_register_dispatch(bell, &token, .main) { _ in
            MainActor.assumeIsolated { handle(app: app) }
        }
        let ready = "status \(Companion.statusNotification)\nrig \(bell)\npid \(getpid())\n"
        try? Data(ready.utf8).write(to: Companion.directory.appending(path: "rig-ready"), options: .atomic)
    }

    private static func handle(app: AppController) {
        guard let text = try? String(contentsOf: Companion.directory.appending(path: "rig-command"), encoding: .utf8)
        else { return }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else { return }
        let (number, verb) = (words[0], words[1])
        func done(after delay: TimeInterval = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                try? Data(number.utf8).write(to: Companion.directory.appending(path: "rig-ack"), options: .atomic)
            }
        }
        switch verb {
        case "menu":
            // Opening blocks while the menu is tracked, so the close is scheduled first, on a timer in
            // the common modes (the main queue is not served while a menu tracks).
            RunLoop.main.add(Timer(timeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated { app.closeMenuForTesting() }
            }, forMode: .common)
            app.openMenuForTesting(appearance: nil)
            done()
        case "settings":
            app.showSettings()
            done(after: 0.5)
        case "settings-close":
            app.settingsWindow?.close()
            done(after: 0.5)
        case "relief":
            malloc_zone_pressure_relief(nil, 0)
            done()
        default:
            break
        }
    }
}
#endif
#endif
