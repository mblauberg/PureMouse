#if DEBUG || DEVHOOKS
import AppKit
import PureMouseAppSupport
import PureMouseKit
import notify

/// Development only: `PUREMOUSE_DEV_MENU=1` opens the menu, so screenshots can be taken without
/// clicking, and `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system appearance. Settings'
/// own hooks are the helper's (`PureMouseSettingsUI.DevHooks`).
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
        // The helper's `PureMouseSettingsUI.DevHooks` reads the same variable the same way.
        switch environment["PUREMOUSE_DEV_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if environment["PUREMOUSE_DEV_MENU"] != nil {
            // The menu's glass shows what is under it: a plain desktop, not whatever is on screen.
            backdrop = plainBackdrop()
            // A status menu follows the menu bar's appearance, not the app's.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.openMenuForTesting(appearance: NSApp.appearance) }
            if let path = environment["PUREMOUSE_DEV_CAPTURE"] {
                // The open menu's own windows, composited without Screen Recording permission, as the
                // helper's capture does; then quit.
                // A timer in the common modes: menu tracking runs its own loop, which a dispatched block
                // waits out.
                let timer = Timer(timeInterval: 3, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        if !writeMenu(to: URL(filePath: path)) { FileHandle.standardError.write(Data("capture failed\n".utf8)) }
                        exit(0)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// This process's on-screen windows but the backdrop, composited into one PNG.
    private static func writeMenu(to url: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var ids: [UnsafeRawPointer?] = info
            .filter { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid }
            .compactMap { $0[kCGWindowNumber as String] as? Int }
            .filter { $0 != backdrop?.windowNumber }
            .compactMap { UnsafeRawPointer(bitPattern: UInt($0)) }
        // Looked up at run time: deprecated for ScreenCaptureKit, which wants the permission.
        typealias Create = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard !ids.isEmpty, let windows = CFArrayCreate(nil, &ids, ids.count, nil),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
              let image = unsafeBitCast(symbol, to: Create.self)(.null, windows, [.boundsIgnoreFraming, .bestResolution])?
                  .takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    private static var backdrop: NSWindow?

    /// `PUREMOUSE_DEV_MENU=1`: a hand-started copy opens only the menu, not Settings as well.
    static var opensMenuOnly: Bool { ProcessInfo.processInfo.environment["PUREMOUSE_DEV_MENU"] != nil }

    /// `PUREMOUSE_DEV_MENU_OPTION=1`: the menu builds as if ⌥ were held, for the detail line.
    static var holdsOption: Bool { ProcessInfo.processInfo.environment["PUREMOUSE_DEV_MENU_OPTION"] != nil }

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
/// `PUREMOUSE_RIG_UPDATES=check` (`--env`) turns automatic update checks on and runs one at launch.
///
/// Verbs: `menu` opens the menu and closes it again, `settings` opens the Settings helper and
/// `settings-close` quits it.
@MainActor
private enum Rig {
    private static var token: Int32 = -1

    static func start(app: AppController) {
        guard Companion.overrideDirectory != nil else { return }
        let bell = Companion.doorbell("io.github.mblauberg.puremouse.rig")
        notify_register_dispatch(bell, &token, .main) { _ in
            MainActor.assumeIsolated { handle(app: app) }
        }
        // `--env PUREMOUSE_RIG_UPDATES=check`: automatic checks on, and one check run now, as the
        // system scheduler would run it. `update-check` in the directory says what it found (the
        // rig's version is not a release number, so any release the check reads counts as newer).
        if ProcessInfo.processInfo.environment["PUREMOUSE_RIG_UPDATES"] == "check" {
            app.updates.setAutomatic(true)
            Task {
                await app.updates.check()
                let found = app.updates.offer.map { $0.version.text } ?? "none"
                try? Data("offer \(found)\n".utf8).write(to: Locations.live.companion.appending(path: "update-check"), options: .atomic)
            }
        }
        let ready = "status \(Companion.statusNotification)\nrig \(bell)\npid \(getpid())\n"
        try? Data(ready.utf8).write(to: Locations.live.companion.appending(path: "rig-ready"), options: .atomic)
    }

    private static func handle(app: AppController) {
        guard let text = try? String(contentsOf: Locations.live.companion.appending(path: "rig-command"), encoding: .utf8)
        else { return }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else { return }
        let (number, verb) = (words[0], words[1])
        func done() {
            try? Data(number.utf8).write(to: Locations.live.companion.appending(path: "rig-ack"), options: .atomic)
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
            done()
        case "settings-close":
            SettingsLauncher.shared.quitRunning()
            done()
        default:
            break
        }
    }
}
#endif
#endif
