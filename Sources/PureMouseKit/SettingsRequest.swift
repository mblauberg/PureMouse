import Foundation

/// The `show-settings` file every opener of Settings writes (the menu bar app with a pane, the
/// daemon's `openMenu` empty) and the app that shows Settings takes, and the `settings-quit` stamp
/// Quit PureMouse leaves beside it. All of it happens under `show-settings.lock`: a request written
/// while another is being read and removed would otherwise be read half written or removed unread.
public enum SettingsRequest {
    /// How long a quit stamp stops a Settings helper that starts late: an open sent before Quit
    /// PureMouse that LaunchServices answers after the menu bar app has gone.
    public static let quitHold: TimeInterval = 60

    /// Asks for Settings: `body` names the pane (empty: the last one shown). Replaces the file
    /// atomically, and clears a quit stamp, since this request comes after it.
    public static func write(_ body: String, to file: URL = Companion.showSettingsURL) {
        try? FileLock.withLock(FileLock.url(for: file)) {
            try Data(body.utf8).write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: quitStamp(beside: file))
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

    /// Quit PureMouse has begun: a Settings helper that starts in the next `quitHold` seconds,
    /// without a request written since, quits at once.
    public static func markQuit(beside file: URL = Companion.showSettingsURL) {
        try? FileLock.withLock(FileLock.url(for: file)) {
            try Data().write(to: quitStamp(beside: file), options: .atomic)
        }
    }

    /// True when Quit PureMouse began less than `quitHold` ago and nothing has asked for Settings
    /// since.
    public static func quitUnderWay(beside file: URL = Companion.showSettingsURL, now: Date = Date()) -> Bool {
        let stamp = quitStamp(beside: file)
        let date = try? FileLock.withLock(FileLock.url(for: file)) {
            (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date
        }
        guard let date = date ?? nil else { return false }
        return now.timeIntervalSince(date) < quitHold
    }

    static func quitStamp(beside file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: "settings-quit")
    }
}
