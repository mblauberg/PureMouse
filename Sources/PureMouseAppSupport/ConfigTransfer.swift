import Foundation
import PureMouseKit

/// Export Settings… and Import Settings…: the config copied out to a file the person chooses, and a
/// chosen file read back in. Neither touches a device: a config holds no pairing and no device
/// state, and an import only replaces the file, so the daemon does what it does for any save and
/// reloads (docs/configuration.md, Export and import).
public enum ConfigTransfer {
    /// A file that passed `ConfigCheck.validate`, ready to replace the config.
    public struct Candidate: Equatable {
        public let data: Data
        /// How many `run` commands the file holds, which the confirmation names: an imported file
        /// can carry commands that then run when a button is pressed.
        public let runCommands: Int
        public let name: String
    }

    /// Why a file was refused. `message` is shown as it is.
    public struct Refusal: Error, Equatable {
        public let message: String
    }

    /// The suggested name of an exported file.
    public static let exportName = "puremouse-settings.json"

    /// Reads and validates `url` as the daemon would load it. A file that fails is refused with the
    /// field named; nothing is written.
    public static func read(_ url: URL) throws(Refusal) -> Candidate {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Refusal(message: "PureMouse can't read \(url.lastPathComponent).")
        }
        do {
            try ConfigCheck.validate(data)
            _ = try ConfigTree(data: data)
        } catch {
            throw Refusal(message: ConfigCheck.message(for: error))
        }
        let tree = (try? ConfigTree(data: data)) ?? ConfigTree()
        return Candidate(data: data, runCommands: tree.runCommandCount, name: url.lastPathComponent)
    }

    /// The confirmation's text: what is replaced and kept, and, when the file has them, the count of
    /// commands it runs.
    public static func confirmation(for candidate: Candidate, backupName: String) -> (title: String, message: String) {
        var message = "Every setting is replaced by the ones in “\(candidate.name)”. "
            + "The current config file is saved as \(backupName), replacing any earlier backup."
        if candidate.runCommands > 0 {
            message += "\n\nThis file runs commands: \(candidate.runCommands)"
        }
        return ("Replace all settings?", message)
    }
}

extension ConfigTree {
    /// The `run` actions in the tree, wherever they are bound (a command is an object with a string
    /// `run` and no `keys`, as `Action` decodes it).
    public var runCommandCount: Int { Self.runCommands(in: root) }

    private static func runCommands(in value: Any) -> Int {
        if let object = value as? [String: Any] {
            let own = object["run"] is String && !(object["keys"] is String) ? 1 : 0
            return own + object.values.reduce(0) { $0 + runCommands(in: $1) }
        }
        if let list = value as? [Any] { return list.reduce(0) { $0 + runCommands(in: $1) } }
        return 0
    }
}

extension ConfigStore {
    /// Writes a copy of the config to `url` (a file the person chose). Edits waiting are saved
    /// first. A config file that does not load is not exported, so a saved file is always valid.
    /// Returns why it failed, or nil.
    public func exportSettings(to url: URL) -> String? {
        flush()
        if let problem = configError { return "The config file has an error, so it wasn't exported: \(problem)" }
        let data: Data
        if FileManager.default.fileExists(atPath: locations.config.path) {
            guard let current = try? Data(contentsOf: locations.config) else {
                return "PureMouse can't read \(Format.tildePath(locations.config.path))."
            }
            data = current
        } else {
            data = ConfigTree().data()
        }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "PureMouse couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Replaces the whole config with a validated file, keeping the previous one as `config.json.bak`
    /// (`ConfigFile.replace`, under the config lock). Nothing else happens: no device is asked
    /// anything, and the daemon reloads because the file changed. Returns why nothing was replaced,
    /// or nil.
    public func importSettings(_ candidate: ConfigTransfer.Candidate) -> String? {
        replace(with: candidate.data)
        return writeError
    }
}
