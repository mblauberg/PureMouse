#if DEBUG
import AppKit

/// Development only: `PUREMOUSE_DEV_CAPTURE=<file.png>` writes the helper's own on-screen windows
/// (the Settings window and any sheet or popover over it) to that PNG after
/// `PUREMOUSE_DEV_CAPTURE_DELAY` seconds (default 2.5), then quits. A process may image its own
/// windows without the Screen Recording permission, so captures work over SSH, where
/// `screencapture -l` is refused. Run it on an unlocked Mac: a locked one draws windows inactive.
@MainActor
enum DevCapture {
    static func schedule(_ environment: [String: String]) {
        guard let path = environment["PUREMOUSE_DEV_CAPTURE"] else { return }
        let delay = environment["PUREMOUSE_DEV_CAPTURE_DELAY"].flatMap(Double.init) ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if !write(to: URL(filePath: path)) { FileHandle.standardError.write(Data("capture failed\n".utf8)) }
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
