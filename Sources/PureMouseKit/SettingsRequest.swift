import Foundation

/// The `show-settings` file every opener of Settings writes (the menu bar app with a pane, the
/// daemon's `openMenu` empty) and the app that shows Settings takes. Both happen under
/// `show-settings.lock`: a request written
/// while another is being read and removed would otherwise be read half written or removed unread.
public enum SettingsRequest {
    /// Asks for Settings: `body` names the pane (empty: the last one shown). Replaces the file
    /// atomically.
    public static func write(_ body: String, to file: URL = Companion.showSettingsURL) {
        try? FileLock.withLock(FileLock.url(for: file)) {
            try Data(body.utf8).write(to: file, options: .atomic)
        }
    }

    /// The request's time and body, removing the file; nil when there is none.
    public static func take(from file: URL = Companion.showSettingsURL) -> (date: Date, body: String)? {
        let taken = try? FileLock.withLock(FileLock.url(for: file)) { () -> (date: Date, body: String)? in
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            else { return nil }
            let body = (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            try? FileManager.default.removeItem(at: file)
            return (date, body)
        }
        return taken ?? nil
    }
}
