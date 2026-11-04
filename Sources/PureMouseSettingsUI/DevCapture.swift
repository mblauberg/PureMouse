#if DEBUG
import AppKit
import ObjectiveC

/// Development only: `PUREMOUSE_DEV_CAPTURE=<file.png>` writes the helper's own on-screen windows
/// (the Settings window and any sheet or popover over it) to that PNG after
/// `PUREMOUSE_DEV_CAPTURE_DELAY` seconds (default 2.5), then quits. A process may image its own
/// windows without the Screen Recording permission, so captures work over SSH, where
/// `screencapture -l` is refused. Run it on an unlocked Mac: a locked one draws windows inactive.
/// `PUREMOUSE_DEV_CAPTURE_OFFSCREEN=1` instead draws each visible window's own view hierarchy,
/// titlebar included, without the window server: it works on a locked Mac and gives true sizes,
/// but materials draw flat. An attached sheet goes to `<file>-sheet.png`.
/// `PUREMOUSE_DEV_CAPTURE_SHADOW=1` keeps the window shadow in an on-screen capture, with the clear
/// margin it falls on, as the README's screenshots have it.
///
/// An offscreen capture first makes the window look key and the app active (`makeKey`;
/// `PUREMOUSE_DEV_CAPTURE_KEY`, default `fake`), renders the frame view's layer tree instead of
/// `cacheDisplay` (which paints every toolbar item's glass platter as a bordered box), draws the
/// selected item's platter and cuts the window's corners. `activate` only asks AppKit politely,
/// which a locked screen ignores; `none` draws the window as it is.
@MainActor
enum DevCapture {
    private static var faked = false
    private static var shadow = false

    static func schedule(_ environment: [String: String]) {
        guard let path = environment["PUREMOUSE_DEV_CAPTURE"] else { return }
        let delay = environment["PUREMOUSE_DEV_CAPTURE_DELAY"].flatMap(Double.init) ?? 2.5
        let offscreen = environment["PUREMOUSE_DEV_CAPTURE_OFFSCREEN"] == "1"
        let key = environment["PUREMOUSE_DEV_CAPTURE_KEY"] ?? "fake"
        shadow = environment["PUREMOUSE_DEV_CAPTURE_SHADOW"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let url = URL(filePath: path)
            let finish = {
                let written = offscreen ? drawOffscreen(to: url) : write(to: url)
                if !written { FileHandle.standardError.write(Data("capture failed\n".utf8)) }
                NSApp.terminateClosingSheets()
            }
            guard offscreen, key != "none" else { return finish() }
            makeKey(fake: key == "fake")
            // A run-loop turn so controls redraw in their key state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                report("before draw")
                finish()
            }
        }
    }

    private static func report(_ moment: String) {
        let window = NSApp.orderedWindows.first { $0.isVisible && $0.sheetParent == nil }
        FileHandle.standardError.write(Data(("\(moment): app active \(NSApp.isActive), key \(window?.isKeyWindow ?? false), "
            + "main \(window?.isMainWindow ?? false)\n").utf8))
    }

    /// Activates the app and makes the front window key. With `fake`, also has every window and
    /// the app answer that they are key, main and active (on a locked screen they never become so),
    /// then tells AppKit and SwiftUI the key state changed so they redraw in it.
    private static func makeKey(fake: Bool) {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        report("start")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        report("after activate")
        guard fake else { return }
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        let windowQueries = ["isKeyWindow", "isMainWindow", "_isKeyWindow", "hasKeyAppearance", "hasMainAppearance",
                             "_hasKeyAppearance", "_hasMainAppearance", "_hasActiveAppearance",
                             "_hasActiveAppearanceIgnoringKeyFocus", "_hasActiveControls"]
        let queries = windowQueries.map { (NSWindow.self as AnyClass, $0) }
            + [(NSApplication.self as AnyClass, "isActive"), (NSApplication.self, "_isActiveApp")]
        for (cls, name) in queries {
            if let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) {
                method_setImplementation(method, imp_implementationWithBlock(yes))
            }
        }
        let forced = NSSelectorFromString("_sendForcedWindowChangedKeyState")
        if window.responds(to: forced) { window.perform(forced) }
        let center = NotificationCenter.default
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        if let frame = window.contentView?.superview { redraw(frame) }
        drawSelectedPlatter(in: window)
        faked = true
        report("after fake")
    }

    /// This process's on-screen windows, front to back, composited into one image.
    private static func write(to url: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var ids: [UnsafeRawPointer?] = info
            .filter { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid }
            .compactMap { ($0[kCGWindowNumber as String] as? Int).flatMap { UnsafeRawPointer(bitPattern: UInt($0)) } }
        guard !ids.isEmpty, let windows = CFArrayCreate(nil, &ids, ids.count, nil),
              let image = composite(windows),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// The front visible window's frame view (content, toolbar and titlebar) drawn into a bitmap,
    /// and its attached sheet, if any, beside it.
    private static func drawOffscreen(to url: URL) -> Bool {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.sheetParent == nil }),
              draw(window, to: url) else { return false }
        if let sheet = window.attachedSheet {
            let name = url.deletingPathExtension().lastPathComponent + "-sheet.png"
            _ = draw(sheet, to: url.deletingLastPathComponent().appendingPathComponent(name))
        }
        return true
    }

    private static func draw(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView else { return false }
        let rep: NSBitmapImageRep
        if faked, window.sheetParent == nil, let image = renderLayers(of: view, scale: window.backingScaleFactor) {
            rep = image
        } else {
            guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: cached)
            rep = cached
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// The frame view's layer tree rendered by Core Animation, clipped to the window's 16 pt
    /// corners. Glass and backdrop layers render as nothing, where `cacheDisplay` paints each
    /// toolbar platter as a bordered box.
    private static func renderLayers(of view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        view.displayIfNeeded()
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: 16 * scale, cornerHeight: 16 * scale, transform: nil))
        context.clip()
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = view.bounds.size
        return rep
    }

    /// The selected toolbar item's platter, which is glass and so renders as nothing offscreen: a
    /// soft fill like a real capture's (dark: white 15%, light: black 2.5%, each with a faint rim).
    private static func drawSelectedPlatter(in window: NSWindow) {
        guard let toolbar = window.toolbar, let selected = toolbar.selectedItemIdentifier,
              let frame = window.contentView?.superview else { return }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let items = toolbar.items.filter { ![.flexibleSpace, .space].contains($0.itemIdentifier) }
        let platters = all(frame).filter { "\(type(of: $0))" == "NSToolbarPlatterView" }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard let index = items.firstIndex(where: { $0.itemIdentifier == selected }), platters.indices.contains(index),
              let effect = platters[index].subviews.first(where: { "\(type(of: $0))" == "NSGlassEffectView" }),
              let layer = effect.layer else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = CAShapeLayer()
        fill.frame = effect.bounds
        fill.path = CGPath(roundedRect: effect.bounds.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 10, cornerHeight: 10,
                           transform: nil)
        fill.fillColor = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.15 : 0.025)
        fill.lineWidth = 0.5
        fill.strokeColor = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.22 : 0.07)
        layer.insertSublayer(fill, at: 0)
    }

    /// `CGWindowListCreateImageFromArray`, looked up at run time: it is deprecated in favour of
    /// ScreenCaptureKit, which needs the Screen Recording permission even for a process's own windows.
    private static func composite(_ windows: CFArray) -> CGImage? {
        typealias Create = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray")
        else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        let options: CGWindowImageOption = shadow ? [.bestResolution] : [.boundsIgnoreFraming, .bestResolution]
        return create(.null, windows, options)?.takeRetainedValue()
    }
}
#endif
