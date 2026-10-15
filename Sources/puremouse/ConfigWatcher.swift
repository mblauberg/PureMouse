import Foundation

/// Calls `onChange` shortly after the config file may have changed, so hand edits and the menu
/// bar app's writes apply on save. Watches the file's directory, since saving usually replaces the
/// file (a new inode, leaving any descriptor on the old one stale), and the file itself, since some
/// editors write in place, which leaves the directory untouched. Events are debounced: a save is
/// often several of them. Idle costs nothing; the debounce is one-shot.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    static let debounce: DispatchTimeInterval = .milliseconds(150)

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        directorySource = watch(url.deletingLastPathComponent().path, [.write])
        if directorySource == nil { Log.error("cannot watch \(url.deletingLastPathComponent().path); reload with SIGHUP") }
        fileSource = watch(url.path, [.write, .extend, .delete, .rename])
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
        // The file may have been replaced; follow the new one.
        fileSource?.cancel()
        fileSource = watch(url.path, [.write, .extend, .delete, .rename])
        onChange()
    }
}
