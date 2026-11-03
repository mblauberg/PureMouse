#if DEBUG
import AppKit

/// Development only: `PUREMOUSE_DEV_CAPTURE=<file.png>` writes the helper's own on-screen windows
/// (the Settings window and any sheet or popover over it) to that PNG after
/// `PUREMOUSE_DEV_CAPTURE_DELAY` seconds (default 2.5), then quits. A process may image its own
/// windows without the Screen Recording permission, so captures work over SSH, where
/// `screencapture -l` is refused. Run it on an unlocked Mac: a locked one draws windows inactive.
/// `PUREMOUSE_DEV_CAPTURE_OFFSCREEN=1` instead draws each visible window's own view hierarchy,
/// titlebar included, without the window server: it works on a locked Mac and gives true sizes,
/// but materials draw flat. An attached sheet goes to `<file>-sheet.png`.
@MainActor
enum DevCapture {
    static func schedule(_ environment: [String: String]) {
        guard let path = environment["PUREMOUSE_DEV_CAPTURE"] else { return }
        let delay = environment["PUREMOUSE_DEV_CAPTURE_DELAY"].flatMap(Double.init) ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let url = URL(filePath: path)
            let written = environment["PUREMOUSE_DEV_CAPTURE_OFFSCREEN"] == "1" ? drawOffscreen(to: url) : write(to: url)
            if !written { FileHandle.standardError.write(Data("capture failed\n".utf8)) }
            NSApp.terminateClosingSheets()
        }
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
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `CGWindowListCreateImageFromArray`, looked up at run time: it is deprecated in favour of
    /// ScreenCaptureKit, which needs the Screen Recording permission even for a process's own windows.
    private static func composite(_ windows: CFArray) -> CGImage? {
        typealias Create = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray")
        else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        return create(.null, windows, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}
#endif
