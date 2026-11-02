import Foundation
import PureMouseKit
import notify

/// "Show Settings": the `show-settings` file, stamped with its time and naming the pane to open
/// (empty: the last one shown) and, after a dot, a sheet to open over it ("pointer.presets"), plus a
/// doorbell, so a process still starting up (and not yet listening) sees it too. Only a request
/// from the last 5 s counts (docs/companion.md).
public struct ShowRequest: Equatable, Sendable {
    /// The pane asked for (a sheet's own, when only the sheet is named); nil opens the last one shown.
    public var pane: SettingsPane?
    /// The sheet to open over the pane.
    public var sheet: SettingsSheet?

    public init(pane: SettingsPane? = nil, sheet: SettingsSheet? = nil) {
        self.pane = pane ?? sheet?.pane
        self.sheet = sheet
    }

    static let freshness: TimeInterval = 5

    /// The file's body: the pane's word, then ".sheet" when there is one.
    var body: String {
        (pane?.rawValue ?? "") + (sheet.map { "." + $0.rawValue } ?? "")
    }

    init(body: String) {
        let parts = body.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", maxSplits: 1,
                                                                              omittingEmptySubsequences: false)
        self.init(pane: parts.first.flatMap { SettingsPane(rawValue: String($0)) },
                  sheet: parts.dropFirst().first.flatMap { SettingsSheet(rawValue: String($0)) })
    }

    public func post() {
        Self.write(self, to: Companion.showSettingsURL)
        notify_post(Companion.showSettingsNotification)
    }

    /// The request posted in the last few seconds, if any; removes the file either way.
    public static func consume() -> ShowRequest? {
        consume(from: Companion.showSettingsURL, now: Date())
    }

    /// Through `SettingsRequest`, under the lock the daemon's writer takes too.
    static func write(_ request: ShowRequest, to file: URL) {
        SettingsRequest.write(request.body, to: file)
    }

    static func consume(from file: URL, now: Date) -> ShowRequest? {
        guard let (date, body) = SettingsRequest.take(from: file), now.timeIntervalSince(date) < freshness else { return nil }
        return ShowRequest(body: body)
    }
}
