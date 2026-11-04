#if DEBUG || DEVHOOKS
import AppKit
import PureMouseAppSupport
import PureMouseKit
import notify

/// Development only: `PUREMOUSE_DEV_MENU=1` opens the menu, so screenshots can be taken without
/// clicking, and `PUREMOUSE_DEV_APPEARANCE=light|dark` overrides the system appearance. Settings'
/// own hooks are the helper's (`PureMouseSettingsUI.DevHooks`).
///
/// `PUREMOUSE_DEV_ICON=<directory>` writes the status icon's looks (running, paused, off, attention, and
/// paused-attention) as PNGs (`running@1x.png`, `running@2x.png`, …) and exits before anything else starts.
/// `PUREMOUSE_DEV_MICE=2` shows the menu as if two mice were online (a fixture: the status is not
/// read for devices), and `PUREMOUSE_DEV_SUBMENU=pointer` shows Pointer Speed's rows as the menu
/// itself, so a capture of it needs no hovering. With the fixture on, choosing a preset or Edit
/// Presets… does nothing.
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
                // The open menu's own windows, as the helper's capture does; then quit.
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

    /// The open menu's windows drawn from their own views, so no Screen Recording permission is
    /// needed: a window server image of them is blank without it. The menu's glass draws nothing
    /// this way, so the drawing goes over the window background colour.
    private static func drawMenu(to url: URL) -> Bool {
        let windows = NSApp.windows.filter { $0.isVisible && $0 !== backdrop }
        guard let window = windows.max(by: { $0.frame.height < $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView else { return false }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        (NSApp.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// This process's on-screen windows but the backdrop, composited into one PNG; without Screen
    /// Recording permission, the menu drawn from its views instead.
    private static func writeMenu(to url: URL) -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return drawMenu(to: url) }
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

    /// `PUREMOUSE_DEV_MICE=2`: two mice online, with their own presets, whatever the daemon reports.
    static func fixture(_ state: inout MenuState) {
        guard ProcessInfo.processInfo.environment["PUREMOUSE_DEV_MICE"] == "2" else { return }
        func mouse(_ name: String, key: String, dpi: Int) -> Status.Device {
            Status.Device(id: key, name: name, connection: .receiver, online: true,
                          battery: .init(percent: 80, level: .good, charging: false), dpi: dpi,
                          dpiSteps: [400, 800, 1200, 1600, 2400, 3200], wheelMode: .ratchet, controls: [], model: key)
        }
        let master = mouse("MX Master 3S", key: "mb03400000000", dpi: 1600)
        let anywhere = mouse("MX Anywhere 3S", key: "mb03300000000", dpi: 1000)
        state.daemonRunning = true
        state.devices = [master, anywhere]
        state.mousePresets = ["mb03400000000": [800, 1600, 3200], "mb03300000000": [400, 800, 1200]]
        state.dpiPresets = [800, 1600]
        state.currentDPI = 1600
    }

    /// While the two-mice fixture is on, the preset rows do nothing: they would write
    /// `devices.mb034…` into whatever config the menu runs on, or open Settings on mice that are not there.
    static func ignores(_ action: MenuAction,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["PUREMOUSE_DEV_MICE"] == "2" else { return false }
        switch action {
        case .setDPI, .setDeviceDPI, .editPresets: return true
        default: return false
        }
    }

    /// `PUREMOUSE_DEV_SUBMENU=pointer`: the rows of that submenu in place of the menu's.
    static func submenu(_ rows: [MenuRow]) -> [MenuRow] {
        guard ProcessInfo.processInfo.environment["PUREMOUSE_DEV_SUBMENU"] == "pointer" else { return rows }
        for case let .item(item) in rows where item.title == "Pointer Speed" { return item.submenu ?? rows }
        return rows
    }

    /// `PUREMOUSE_DEV_ICON=<directory>`: writes the status icon's five looks at 1x and 2x. True when
    /// it was asked for, and the caller exits.
    static func writeIcons() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_ICON"] else { return false }
        writeIcons(to: URL(filePath: path, directoryHint: .isDirectory))
        return true
    }

    static func writeIcons(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let looks: [(String, StatusIcon.Look, StatusIcon.Badge)] = [
            ("running", .running, .none), ("paused", .paused, .none), ("off", .off, .none),
            ("attention", .running, .attention), ("paused-attention", .paused, .attention),
        ]
        for (name, look, badge) in looks {
            let image = StatusIcon.image(look: look, badge: badge)
            for scale in 1...2 {
                let size = image.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                                 pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: rep)
                else { continue }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                // The image redraws itself for the larger rect, as it does on a 2x display.
                image.draw(in: NSRect(x: 0, y: 0, width: size.width * CGFloat(scale), height: size.height * CGFloat(scale)))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "\(name)@\(scale)x.png"))
            }
        }
    }

    /// `PUREMOUSE_DEV_MENU=1`: a hand-started copy opens only the menu, not Settings as well.
    static var opensMenuOnly: Bool { ProcessInfo.processInfo.environment["PUREMOUSE_DEV_MENU"] != nil }

    /// `PUREMOUSE_DEV_FRONT=<bundle id>` (with `PUREMOUSE_DEV_FRONT_NAME=<name>`): the menu builds as
    /// if that app were frontmost, for "Settings for <app>…" and "Off in <app>".
    static var frontmost: (bundleID: String, name: String?)? {
        let environment = ProcessInfo.processInfo.environment
        return environment["PUREMOUSE_DEV_FRONT"].map { ($0, environment["PUREMOUSE_DEV_FRONT_NAME"]) }
    }

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
