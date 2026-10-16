import CoreGraphics
import Darwin
import Foundation

/// Which app is frontmost, or under the pointer, by bundle ID. AppKit-free (NSWorkspace and
/// NSRunningApplication live in AppKit) and asked only when something needs the answer, at a
/// press or the start of a scroll: no observers, no polling.
///
/// - Frontmost: the window server's front process (private `_SLPSGetFrontProcess`, as yabai and
///   AltTab use; a few microseconds), else the owner of the frontmost ordinary window. The
///   Accessibility focused-application attribute is public but took 8–40 ms here, or failed.
///   While Universal Control has the pointer on another Mac, the frontmost app is
///   `com.apple.universalcontrol`.
/// - Under the pointer: the owner of the frontmost ordinary window containing it, from the
///   on-screen window list (about 1 ms), remembered for `pointerMemory` so a scroll burst that
///   asks twice (thumb wheel action and scroll profile) looks once.
@MainActor
final class ForegroundApp {
    static let shared = ForegroundApp()

    private var bundleIDs = BundleIDCache()
    private var lastPointer: (at: ContinuousClock.Instant, point: CGPoint, bundleID: String?)?
    private static let pointerMemory: Duration = .milliseconds(50)

    func frontmost() -> String? {
        let pid = Self.frontProcessPID() ?? Self.windowOwner(at: nil)
        return pid.flatMap { bundleIDs.bundleID(forPID: $0) }
    }

    func underPointer() -> String? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        let now = ContinuousClock.now
        if let last = lastPointer, last.point == point, now - last.at < Self.pointerMemory { return last.bundleID }
        let bundleID = Self.windowOwner(at: point).flatMap { bundleIDs.bundleID(forPID: $0) }
        lastPointer = (now, point, bundleID)
        return bundleID
    }

    private typealias GetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias GetProcessPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> Int32
    private static let frontProcess: (GetFrontProcess, GetProcessPID)? = {
        // SkyLight holds the window server's notion of the front process; GetProcessPID (HIServices,
        // deprecated) turns its serial number into a pid. Neither is otherwise linked.
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let front = dlsym(skyLight, "_SLPSGetFrontProcess"),
              let toPID = dlsym(services, "GetProcessPID") else {
            Log.error("front process lookup unavailable; using the frontmost window's app")
            return nil
        }
        return (unsafeBitCast(front, to: GetFrontProcess.self), unsafeBitCast(toPID, to: GetProcessPID.self))
    }()

    private static func frontProcessPID() -> pid_t? {
        guard let (front, toPID) = frontProcess else { return nil }
        var psn = ProcessSerialNumber()
        var pid: pid_t = 0
        guard front(&psn) == 0, toPID(&psn, &pid) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The owner of the frontmost ordinary (layer 0, visible) window, containing `point` if given.
    /// The list runs front to back; window titles need Screen Recording, but owners and bounds do not.
    private static func windowOwner(at point: CGPoint?) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
            if let point {
                guard let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                        .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                      bounds.contains(point) else { continue }
            }
            return pid
        }
        return nil
    }
}

/// Bundle IDs by executable path. The path is read for each lookup (one syscall), so a reused
/// pid cannot return a stale app; the Info.plist read is what the cache saves.
struct BundleIDCache {
    private var byPath: [String: String?] = [:]
    /// Bounded, so many short-lived processes cannot grow it.
    static let capacity = 64

    mutating func bundleID(forPID pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return bundleID(forExecutable: String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
    }

    mutating func bundleID(forExecutable path: String,
                           read: (String) -> String? = Self.readBundleID(appBundle:)) -> String? {
        if let cached = byPath[path] { return cached }
        let id = Self.appBundle(forExecutable: path).flatMap(read)
        if byPath.count >= Self.capacity { byPath.removeAll(keepingCapacity: true) }
        byPath[path] = id
        return id
    }

    /// The innermost `.app` holding an executable: a helper app's own bundle, not its host's.
    static func appBundle(forExecutable path: String) -> String? {
        var components = path.split(separator: "/", omittingEmptySubsequences: false)
        while let last = components.last {
            if last.hasSuffix(".app") { return components.joined(separator: "/") }
            components.removeLast()
        }
        return nil
    }

    static func readBundleID(appBundle path: String) -> String? {
        let url = URL(fileURLWithPath: path, isDirectory: true) as CFURL
        guard let info = CFBundleCopyInfoDictionaryInDirectory(url) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}
