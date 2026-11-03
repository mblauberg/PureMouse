import Foundation

/// Calls `onChange` shortly after the config file may have changed, so hand edits and the menu
/// bar app's writes apply on save. Watches the file's directory, since saving usually replaces the
/// file (a new inode, leaving any descriptor on the old one stale), and the file itself, since some
/// editors write in place, which leaves the directory untouched. A directory that is a symlink (a
/// dotfiles setup) is watched at the folder it points to, and the parent of the directory as
/// written and of every link on the way is watched too, so a link or target swapped or replaced
/// at any hop is followed. While the directory is absent (deleted, renamed away, a dangling link,
/// or never created) the nearest ancestor of where it would be is watched instead, so its return
/// is noticed; `onChange` is not called while it is absent, so the config in effect stays. Every
/// event re-resolves the path and re-arms the watches, since a descriptor on a replaced directory
/// or file is stale. A change to a parent alone reloads only if the directory it leads to changed.
/// Events are debounced: a save is often several of them. Renaming a real directory above the
/// watched parents is not noticed (SIGHUP reloads). File-system sources only: idle costs nothing,
/// and the debounce is one-shot. Releasing the watcher, or `stop()`, closes its descriptors.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var directorySource: Watch?
    private var parentSources: [Watch] = []
    private var fileSource: Watch?
    /// Whether the config's own directory exists, so the directory source watches it and not an
    /// ancestor.
    private var directoryExists = false
    /// The directory the path led to when last armed, to tell a replaced one from an unchanged one.
    private var directoryID: FileID?
    /// Every event since the last reload came from the directory's parent.
    private var parentOnly = true
    private var pending: DispatchWorkItem?
    private static let maximumLinks = 8
    static let debounce: DispatchTimeInterval = .milliseconds(150)
    private static let directoryEvents: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
    private static let fileEvents: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename]

    /// One open descriptor and its source; the descriptor closes when the source is cancelled,
    /// which dropping the watch does.
    private final class Watch {
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32

        init(source: DispatchSourceFileSystemObject, descriptor: Int32) {
            self.source = source
            self.descriptor = descriptor
        }

        func cancel() { source.cancel() }

        deinit { source.cancel() }
    }

    private struct FileID: Hashable {
        var device: dev_t
        var inode: ino_t
    }

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    /// The descriptors held now, for tests.
    var descriptors: [Int32] {
        ([directorySource, fileSource] + parentSources).compactMap { $0?.descriptor }
    }

    /// Stops watching and closes every descriptor; nothing reloads after it.
    func stop() {
        pending?.cancel()
        pending = nil
        ([directorySource, fileSource] + parentSources).forEach { $0?.cancel() }
        directorySource = nil
        parentSources = []
        fileSource = nil
    }

    /// Watches the directory and the file, or, with the directory absent, the nearest existing
    /// ancestor of where it leads; and the directory's parent as written. A directory that appears
    /// while arming is picked up by arming again.
    private func arm() {
        let literal = url.deletingLastPathComponent()
        let parent = literal.deletingLastPathComponent()
        for _ in 0..<3 {
            ([directorySource, fileSource] + parentSources).forEach { $0?.cancel() }
            directorySource = nil
            parentSources = []
            fileSource = nil
            let (directory, linkParents) = Self.followingLinks(literal)
            var anchor = directory
            while !Self.isDirectory(anchor), anchor.path != "/" {
                anchor = anchor.deletingLastPathComponent()
            }
            directoryExists = anchor == directory
            directoryID = directoryExists ? Self.fileID(directory) : nil
            directorySource = watch(anchor.path, Self.directoryEvents, fromParent: false)
            if directorySource == nil { Log.error("cannot watch \(anchor.path); reload with SIGHUP") }
            // The directory's parent as written, and the parent of every link on the way to it.
            var watched = Set([Self.fileID(anchor)].compactMap { $0 })
            for folder in [parent] + linkParents {
                guard let id = Self.fileID(folder), watched.insert(id).inserted,
                      let watch = watch(folder.path, Self.directoryEvents, fromParent: true) else { continue }
                parentSources.append(watch)
            }
            if directoryExists {
                fileSource = watch(url.path, Self.fileEvents, fromParent: false)
            } else if Self.isDirectory(directory) {
                continue
            }
            return
        }
    }

    /// `url` with a symlink as its last component followed, even to a place that does not exist
    /// (a link in the middle of a target path is not followed; see how-it-works),
    /// and the folder holding each link followed (at most `maximumLinks`; a longer chain goes
    /// unfollowed past that, and SIGHUP reloads).
    private static func followingLinks(_ url: URL) -> (url: URL, linkParents: [URL]) {
        var url = url
        var parents: [URL] = []
        for _ in 0..<maximumLinks {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            let parent = url.deletingLastPathComponent()
            parents.append(parent)
            url = URL(fileURLWithPath: target, relativeTo: parent).standardizedFileURL
        }
        return (url, parents)
    }

    private static func fileID(_ url: URL) -> FileID? {
        var info = stat()
        return stat(url.path, &info) == 0 ? FileID(device: info.st_dev, inode: info.st_ino) : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func watch(_ path: String, _ events: DispatchSource.FileSystemEvent,
                       fromParent: Bool) -> Watch? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed(fromParent: fromParent) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return Watch(source: source, descriptor: fd)
    }

    private func changed(fromParent: Bool) {
        parentOnly = (pending == nil ? true : parentOnly) && fromParent
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settled() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func settled() {
        pending = nil
        let hadDirectory = directoryExists
        let before = directoryID
        let onlyParent = parentOnly
        // The directory or file may have been replaced, or the directory may be gone or back.
        arm()
        if directoryExists {
            // Something else in the parent changed, not the directory this path leads to.
            if onlyParent, hadDirectory, directoryID == before { return }
            onChange()
        } else if hadDirectory {
            Log.info("\(url.deletingLastPathComponent().path) is gone; keeping the current config until it returns")
        }
    }
}
