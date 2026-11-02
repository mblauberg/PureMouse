import Foundation
import PureMouseKit

/// The config file on disk. Saving replays the app's edits onto the file as it is at that moment,
/// so a hand edit made since it was loaded is kept (docs/companion.md: the app owns only the keys
/// it changes).
public struct ConfigFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    enum SaveError: Error {
        /// The file on disk does not load now; nothing is built on it.
        case fileHasError
        /// The edited config would not load (the daemon's own check).
        case rejected(Error)
        case writeFailed(Error)
        /// The current file could not be kept as the backup, so it was left as it was.
        case backupFailed(Error)
    }

    /// The file itself: a symlinked config (dotfiles) resolves to its target.
    var target: URL { url.resolvingSymlinksInPath() }

    /// Where `replace(with:keepingBackup:)` keeps the previous file: beside the target, one
    /// generation (`config.json.bak`).
    public var backupURL: URL { target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".bak") }

    /// Every write (save, replace, create) is one read-merge-replace under an exclusive `flock` on
    /// `config.json.lock` beside the target, so writers in other processes never drop each
    /// other's keys. Hand edits do not take it; replaying edits onto the file as it is keeps them.
    var lockURL: URL { FileLock.url(for: target) }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        do {
            return try FileLock.withLock(lockURL, body)
        } catch let error as FileLock.Failed {
            throw SaveError.writeFailed(error)
        }
    }

    /// Replays `changes` onto the current file and writes the result when it differs. Returns
    /// the tree and the bytes now on disk (nil when there is still no file).
    public func save(_ changes: [ConfigTree.Change]) throws -> (tree: ConfigTree, data: Data?) {
        try locked { try saveLocked(changes) }
    }

    private func saveLocked(_ changes: [ConfigTree.Change]) throws -> (tree: ConfigTree, data: Data?) {
        let current: Data?
        var tree: ConfigTree
        do {
            current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            tree = try current.map { try ConfigTree(data: $0) } ?? ConfigTree()
            if let current { try ConfigCheck.validate(current) }
        } catch {
            throw SaveError.fileHasError
        }
        tree.apply(changes)
        let data = tree.data()
        guard data != current else { return (tree, current) }
        do {
            try ConfigCheck.validate(data)
        } catch {
            throw SaveError.rejected(error)
        }
        try write(data)
        return (tree, data)
    }

    /// Replaces the whole file (Reset All Settings, Restore Last Working). With `keepingBackup`,
    /// the current file is first copied to `backupURL`, replacing an earlier backup, unless there
    /// is nothing to keep: no file, or one that parses to an object with no keys (an earlier
    /// backup is then left alone). If the backup cannot be written, the file is left as it was.
    public func replace(with data: Data, keepingBackup: Bool) throws {
        try locked { try replaceLocked(with: data, keepingBackup: keepingBackup) }
    }

    private func replaceLocked(with data: Data, keepingBackup: Bool) throws {
        if keepingBackup {
            do {
                let target = target
                if FileManager.default.fileExists(atPath: target.path) {
                    let current = try Data(contentsOf: target)
                    let empty = (try? ConfigTree(data: current))?.root.isEmpty == true
                    if !empty { try current.write(to: backupURL, options: .atomic) }
                }
            } catch {
                throw SaveError.backupFailed(error)
            }
        }
        try write(data)
    }

    /// Creates an empty config (`{}`) when there is none, so it can be opened in an editor; never
    /// touches an existing file and keeps no backup. Returns the bytes written, or nil when the
    /// file was already there.
    @discardableResult
    public func createIfMissing() throws -> Data? {
        try locked {
            guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = ConfigTree().data()
            try write(data)
            return data
        }
    }

    /// Replaces the file; the caller holds the lock. A symlinked config (dotfiles) has its target
    /// replaced, not the link.
    private func write(_ data: Data) throws {
        let target = target
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw SaveError.writeFailed(error)
        }
    }
}
