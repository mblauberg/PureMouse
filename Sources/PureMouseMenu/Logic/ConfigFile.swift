import Foundation
import PureMouseKit

/// The config file on disk. Saving replays the app's edits onto the file as it is at that moment,
/// so a hand edit made since it was loaded is kept (docs/companion.md: the app owns only the keys
/// it changes).
struct ConfigFile {
    let url: URL

    enum SaveError: Error {
        /// The file on disk does not load now; nothing is built on it.
        case fileHasError
        /// The edited config would not load (the daemon's own check).
        case rejected(Error)
        case writeFailed(Error)
    }

    /// Replays `changes` onto the current file and writes the result when it differs. Returns
    /// the tree and the bytes now on disk (nil when there is still no file).
    func save(_ changes: [ConfigTree.Change]) throws -> (tree: ConfigTree, data: Data?) {
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

    /// Replaces the file. A symlinked config (dotfiles) has its target replaced, not the link.
    func write(_ data: Data) throws {
        let target = url.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw SaveError.writeFailed(error)
        }
    }
}
