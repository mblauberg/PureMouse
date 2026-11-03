import Foundation
import Observation
import PureMouseKit

/// The config file as Settings and the menu edit it: the tree (re-read when the file or its
/// directory changes), edits not yet saved, and the last config that loaded. No timers and no
/// polling: file and directory sources wake it, and a reload compares bytes.
///
/// `config` is the tree the daemon would decode: the file laid over the default set
/// (`ConfigTree.layered()`), so a missing file, `{}` and Reset All Settings all read as the
/// defaults. An edit is saved as the keys it changes, so a setting left at its default stays out
/// of the file.
@MainActor @Observable
public final class ConfigStore {
    public private(set) var config = ConfigTree.defaults
    /// Why the file on disk cannot be used (unreadable, not JSON, or rejected by the decoder).
    private(set) var configProblem: String?
    /// Why the last change could not be saved.
    public private(set) var writeError: String?

    /// Called when anything the status item shows may have changed.
    @ObservationIgnored public var changed: @MainActor () -> Void = {}
    /// Called at the end of every `flush`, whether or not it wrote.
    @ObservationIgnored public var flushed: @MainActor () -> Void = {}
    /// The daemon's complaint about the file, if any (it may reject what this side accepts).
    @ObservationIgnored public var daemonConfigError: @MainActor () -> String? = { nil }

    @ObservationIgnored public let locations: Locations
    /// Undo and redo for the changes made here: only the Settings helper has one
    /// (`AppModel.undoManager`), so the menu bar app keeps no history.
    @ObservationIgnored private(set) var undo: UndoHistory?
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var diskBytes: Data?
    @ObservationIgnored private var lastGood: Data?
    @ObservationIgnored private var cancelPendingWrite: Clock.Cancel?
    /// Edits made here and not yet saved, as the keys they set. Saving replays them onto the file
    /// as it is then, so a hand edit made meanwhile is kept.
    @ObservationIgnored private var pendingChanges: [ConfigTree.Change] = []
    @ObservationIgnored private var directoryWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatch: DispatchSourceFileSystemObject?

    /// Slider writes wait this long after the last change.
    static let debounce: TimeInterval = 0.3

    public init(locations: Locations, clock: Clock = .main) {
        self.locations = locations
        self.clock = clock
    }

    /// Registers every change made here on `manager` from now on, each named for the Edit menu
    /// and undone by replaying its inverse onto the file (`replay`).
    public func keepHistory(on manager: UndoManager) {
        undo = UndoHistory(manager: manager) { [weak self] changes in
            self?.replay(changes)
        }
    }

    /// Puts an undo's or redo's keys back in the file, and registers the opposite step. This works
    /// on the file's own keys, not the tree laid over the defaults that `update` diffs: a key the
    /// file held at its default value is a change here, though not to `update`. A store that
    /// refuses edits (read-only) has no steps that would do anything, so the history goes.
    func replay(_ changes: [ConfigTree.Change]) {
        guard !readOnly else {
            undo?.clear()
            return
        }
        let before = fileTree
        pendingChanges += changes
        var after = before
        after.apply(changes)
        config = fileTree.layered()
        undo?.record(from: before, to: after, debounce: false)
        flush()
    }

    private var file: ConfigFile { ConfigFile(url: locations.config) }

    /// The file Reset All Settings and Restore Last Working keep the previous config in.
    public var backupName: String { file.backupURL.lastPathComponent }

    /// The daemon's or this side's complaint about the config file.
    public var configError: String? { configProblem ?? daemonConfigError() }

    /// Read-only while the config file has an error: editing would build on a file the daemon is
    /// not using.
    public var readOnly: Bool { configError != nil }

    /// Edits are waiting to be saved.
    public var hasPendingChanges: Bool { !pendingChanges.isEmpty }

    /// Re-reads the config file. Our own writes come back as no-ops (same bytes).
    public func reloadConfig() {
        let url = locations.config
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Deleted while a change of ours waits: save it as a new file now.
            if !pendingChanges.isEmpty {
                if diskBytes != nil {
                    // The steps were made against the file that is gone.
                    undo?.clear()
                    flush()
                }
                return
            }
            // No file: the daemon runs with the default set.
            if diskBytes != nil || configProblem != nil || JSON.encode(config.root) != JSON.encode(ConfigTree.defaults.root) {
                undo?.clear()
                config = ConfigTree.defaults
                configProblem = nil
                diskBytes = nil
                lastGood = Data("{}\n".utf8)
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            configProblem = "PureMouse can't read \(Format.tildePath(url.path))."
            // Read-only now, and unknown to the steps.
            undo?.clear()
            return
        }
        guard data != diskBytes else { return }
        // Someone else changed the file: what the steps would put back no longer fits it.
        undo?.clear()
        // Edited by hand while a change of ours waits: save ours on top of the new file now.
        if !pendingChanges.isEmpty {
            flush()
            return
        }
        diskBytes = data
        if let tree = try? ConfigTree(data: data) { config = tree.layered() }
        do {
            try ConfigCheck.validate(data)
            configProblem = nil
            lastGood = data
        } catch {
            configProblem = ConfigCheck.message(for: error)
        }
        writeError = nil
        changed()
    }

    /// Sets or (with nil) removes one key. Sliders pass `debounce` so dragging writes once it rests.
    public func set(_ value: Any?, at path: [String], debounce: Bool = false) {
        update(debounce: debounce) { $0.set(value, at: path) }
    }

    public func update(debounce: Bool = false, _ change: (inout ConfigTree) -> Void) {
        guard !readOnly else { return }
        let before = config
        let fileBefore = undo == nil ? nil : fileTree
        var tree = before
        change(&tree)
        let changes = before.changes(to: tree)
        pendingChanges += changes
        config = tree.layered()
        if var fileAfter = fileBefore {
            fileAfter.apply(changes)
            undo?.record(from: fileBefore!, to: fileAfter, debounce: debounce)
        }
        if debounce {
            cancelPendingWrite?()
            cancelPendingWrite = clock.after(Self.debounce) { [weak self] in self?.flush() }
        } else {
            flush()
        }
    }

    /// The file as it will be once the edits waiting are saved: only what it holds, without the
    /// default set under it. Undo puts back these keys, so a setting the file never held does not
    /// appear in it with the default's value.
    private var fileTree: ConfigTree {
        var tree = diskBytes.flatMap { try? ConfigTree(data: $0) } ?? ConfigTree()
        tree.apply(pendingChanges)
        return tree
    }

    /// Saves pending edits now (also when Settings closes and before quitting). Writes nothing
    /// when there are none, and never builds on a file that does not load.
    public func flush() {
        cancelPendingWrite?()
        cancelPendingWrite = nil
        undo?.flushed()
        defer { flushed() }
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges = []
        do {
            let saved = try file.save(changes)
            config = saved.tree.layered()
            diskBytes = saved.data
            if let data = saved.data { lastGood = data }
            writeError = nil
            if directoryWatch == nil { startWatching() }
        } catch {
            // Show the file as it is now, then say why the change did not land.
            undo?.clear()
            diskBytes = nil
            reloadConfig()
            writeError = describeSave(error)
        }
    }

    /// Replaces the whole file with `{}` (every setting back to the default set), keeping the
    /// previous file as `config.json.bak` (`ConfigFile.replace`).
    public func resetAll() {
        replace(with: ConfigTree().data())
    }

    /// Puts back the last config that loaded, after a hand edit broke it.
    public var canRestoreLastWorking: Bool { lastGood != nil && configProblem != nil }

    /// Puts back the last config that loaded, keeping the broken file as `config.json.bak`.
    public func restoreLastWorking() {
        guard let lastGood else { return }
        replace(with: lastGood)
    }

    /// Opens the way for Open Config File: creates `{}` when there is no file. Never resets or
    /// backs up, and leaves edits waiting to be saved as they are.
    public func createIfMissing() {
        do {
            guard let data = try file.createIfMissing() else { return }
            if pendingChanges.isEmpty {
                config = ConfigTree.defaults
                configProblem = nil
                lastGood = data
            }
            diskBytes = data
            writeError = nil
            if directoryWatch == nil { startWatching() }
        } catch {
            writeError = describeSave(error)
        }
    }

    private func replace(with data: Data) {
        guard let tree = try? ConfigTree(data: data) else { return }
        undo?.clear()
        cancelPendingWrite?()
        cancelPendingWrite = nil
        pendingChanges = []
        do {
            try file.replace(with: data, keepingBackup: true)
            config = tree.layered()
            configProblem = nil
            diskBytes = data
            lastGood = data
            writeError = nil
            if directoryWatch == nil { startWatching() }
        } catch {
            // Nothing was replaced: show the file as it is, then say why.
            diskBytes = nil
            reloadConfig()
            writeError = describeSave(error)
        }
        changed()
    }

    private func describeSave(_ error: Error) -> String {
        switch error {
        case ConfigFile.SaveError.fileHasError:
            "The config file changed and has an error, so this change wasn't saved."
        case ConfigFile.SaveError.rejected(let reason):
            ConfigCheck.message(for: reason)
        case ConfigFile.SaveError.writeFailed(let reason):
            "PureMouse couldn't save \(Format.tildePath(locations.config.path)): \(reason.localizedDescription)"
        case ConfigFile.SaveError.backupFailed(let reason):
            "PureMouse couldn't keep the current file as \(backupName), "
                + "so this change wasn't saved: \(reason.localizedDescription)"
        default:
            error.localizedDescription
        }
    }

    // MARK: Watching

    /// Saving usually replaces the file (a new inode, leaving a descriptor on the old one stale), so
    /// watch the directory; some editors write in place, which leaves the directory untouched, so
    /// watch the file too, following each new one. `reloadConfig` compares bytes, so a save seen
    /// by both costs one read.
    public func startWatching() {
        directoryWatch?.cancel()
        directoryWatch = nil
        let directory = locations.config.resolvingSymlinksInPath().deletingLastPathComponent()
        directoryWatch = watch(directory.path, [.write, .delete, .rename]) { store, events in
            if !events.isDisjoint(with: [.delete, .rename]) { store.startWatching() }
            store.configChanged()
        }
        watchConfigFile()
    }

    private func watchConfigFile() {
        fileWatch?.cancel()
        fileWatch = watch(locations.config.resolvingSymlinksInPath().path, [.write, .extend, .delete, .rename]) { store, _ in
            store.configChanged()
        }
    }

    private func configChanged() {
        watchConfigFile()  // the file may have been replaced; follow the new one
        reloadConfig()
    }

    private func watch(_ path: String, _ events: DispatchSource.FileSystemEvent,
                       _ handler: @escaping @MainActor (ConfigStore, DispatchSource.FileSystemEvent) -> Void)
        -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                handler(self, source.data)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
