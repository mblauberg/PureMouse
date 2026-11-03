import Foundation

/// Calls `onChange` shortly after the config file may have changed, so hand edits and the menu
/// bar app's writes apply on save. Watches the file's directory, since saving usually replaces the
/// file (a new inode, leaving any descriptor on the old one stale), and the file itself, since some
/// editors write in place, which leaves the directory untouched. While the directory is absent
/// (deleted, renamed away, or never created) it watches the nearest ancestor that exists instead,
/// so the directory's return is noticed; `onChange` is not called while it is absent, so the
/// config in effect stays. Every event re-arms the watches, since a descriptor on a replaced
/// directory or file is stale. Events are debounced: a save is often several of them. These are
/// file-system sources only: idle costs nothing, and the debounce is one-shot.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    /// Whether the config's own directory exists, so the directory source watches it and not an
    /// ancestor.
    private var directoryExists = false
    private var pending: DispatchWorkItem?
    static let debounce: DispatchTimeInterval = .milliseconds(150)
    private static let directoryEvents: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
    private static let fileEvents: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename]

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    /// Watches the directory and the file, or, with the directory absent, its nearest existing
    /// ancestor. A directory that appears while arming is picked up by arming again.
    private func arm() {
        for _ in 0..<3 {
            directorySource?.cancel()
            fileSource?.cancel()
            directorySource = nil
            fileSource = nil
            let directory = url.deletingLastPathComponent()
            var anchor = directory
            while !Self.isDirectory(anchor), anchor.path != "/" {
                anchor = anchor.deletingLastPathComponent()
            }
            directoryExists = anchor == directory
            directorySource = watch(anchor.path, Self.directoryEvents)
            if directorySource == nil { Log.error("cannot watch \(anchor.path); reload with SIGHUP") }
            if directoryExists {
                fileSource = watch(url.path, Self.fileEvents)
            } else if Self.isDirectory(directory) {
                continue
            }
            return
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func watch(_ path: String, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settled() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func settled() {
        pending = nil
        let hadDirectory = directoryExists
        // The directory or file may have been replaced, or the directory may be gone or back.
        arm()
        if directoryExists {
            onChange()
        } else if hadDirectory {
            Log.info("\(url.deletingLastPathComponent().path) is gone; keeping the current config until it returns")
        }
    }
}
