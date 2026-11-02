import Foundation
import PureMouseKit

/// A release newer than the running PureMouse, as the menu and the notification offer it.
public struct UpdateOffer: Equatable, Sendable {
    public var version: UpdateCheck.Version
    public var page: URL

    public init(version: UpdateCheck.Version, page: URL) {
        self.version = version
        self.page = page
    }

    /// "PureMouse 1.2.3 is available".
    public var title: String { "PureMouse \(version.text) is available" }
    public var body: String { "Click to read what's new." }
    /// One notification per version: posting it again replaces it, and skipping takes it down.
    public var notificationID: String { "update.\(version.text)" }
    /// The menu row.
    public var menuTitle: String { "Update to \(version.text)…" }
    public static let skipTitle = "Skip This Version"
}

/// The one question PureMouse asks about automatic checks, asked once (`UpdateReminders.shouldAsk`).
public enum UpdateQuestion {
    public static let title = "Check for updates automatically?"
    public static let message = "PureMouse can ask GitHub once a day whether a new release is out, and tell you if one is. It never installs anything by itself. You can change this in Settings › About."
    public static let accept = "Check Automatically"
    public static let decline = "Don't Check"
}

/// What the update checks remember, in the menu bar app's preferences domain
/// (`io.github.mblauberg.puremouse.menu`): the menu app reads and writes it, and Settings'
/// About pane reads and writes the one switch (`automatic`) through `NotificationPermission.menuDefaults`,
/// the way it reads the notification answer. `docs/privacy.md` lists the keys.
public struct UpdatePreferences {
    public static let automaticKey = "UpdatesAutomatic"
    private static let launchesKey = "UpdatesLaunches"
    private static let lastCheckKey = "UpdatesLastCheck"
    private static let etagKey = "UpdatesETag"
    private static let latestKey = "UpdatesLatestVersion"
    private static let latestPageKey = "UpdatesLatestPage"
    private static let skippedKey = "UpdatesSkippedVersion"
    private static let notifiedKey = "UpdatesNotifiedVersion"

    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults) { self.defaults = defaults }

    /// The answer: nil until the question has been answered or the switch used.
    public var automatic: Bool? {
        get { defaults.object(forKey: Self.automaticKey) as? Bool }
        nonmutating set { set(newValue, Self.automaticKey) }
    }

    /// How many launches of the menu bar app, with its icon shown, have happened before the answer.
    public var launches: Int {
        get { defaults.integer(forKey: Self.launchesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.launchesKey) }
    }

    /// When the last request was made, whether or not it succeeded.
    public var lastCheck: Date? {
        get { (defaults.object(forKey: Self.lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        nonmutating set { set(newValue?.timeIntervalSince1970, Self.lastCheckKey) }
    }

    /// The ETag of the release in `latest`.
    public var etag: String? {
        get { defaults.string(forKey: Self.etagKey) }
        nonmutating set { set(newValue, Self.etagKey) }
    }

    /// The latest release the last successful check found, newer than this app or not.
    public var latest: UpdateCheck.Release? {
        get {
            guard let text = defaults.string(forKey: Self.latestKey), let version = UpdateCheck.Version(text),
                  let page = defaults.string(forKey: Self.latestPageKey).flatMap(URL.init(string:)),
                  page.scheme == "https" else { return nil }
            return UpdateCheck.Release(version: version, page: page)
        }
        nonmutating set {
            set(newValue?.version.text, Self.latestKey)
            set(newValue?.page.absoluteString, Self.latestPageKey)
        }
    }

    /// The version whose reminders the person turned off.
    public var skipped: UpdateCheck.Version? {
        get { defaults.string(forKey: Self.skippedKey).flatMap(UpdateCheck.Version.init) }
        nonmutating set { set(newValue?.text, Self.skippedKey) }
    }

    /// The newest version a notification was posted for.
    public var notified: UpdateCheck.Version? {
        get { defaults.string(forKey: Self.notifiedKey).flatMap(UpdateCheck.Version.init) }
        nonmutating set { set(newValue?.text, Self.notifiedKey) }
    }

    private func set(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Calls `changed` each time the answer is written, from this process or another (Settings'
    /// switch, for as long as it is kept). Key-value observing hears another process's writes;
    /// `UserDefaults.didChangeNotification` does not.
    public final class Watch: NSObject {
        private let defaults: UserDefaults
        private let changed: @MainActor () -> Void

        public init(_ defaults: UserDefaults, changed: @escaping @MainActor () -> Void) {
            self.defaults = defaults
            self.changed = changed
            super.init()
            defaults.addObserver(self, forKeyPath: UpdatePreferences.automaticKey, context: nil)
        }

        deinit { defaults.removeObserver(self, forKeyPath: UpdatePreferences.automaticKey) }

        override public func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                          change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            Task { @MainActor [changed] in changed() }
        }
    }
}

/// Runs a piece of work once, some time from now, when the system finds it convenient (not while
/// the Mac sleeps or is busy). The live one is `NSBackgroundActivityScheduler`; there is no timer
/// of ours behind it, so an idle menu bar app still costs nothing.
@MainActor
public protocol UpdateScheduling: AnyObject {
    /// `work` receives a completion to call once it is done. A new schedule replaces the last.
    func schedule(after delay: TimeInterval, work: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void)
    func cancel()
}

/// The daily check and the reminders it earns: one notification per version, a menu row until
/// PureMouse is updated, and a way to skip a version. Nothing here installs anything.
///
/// The check runs only while `automatic` is on, at most once every 24 hours counted from the last
/// request (kept across launches), whether that request worked or not. The clock, the fetcher,
/// the scheduler and the notification are all injected.
@MainActor
public final class UpdateReminders {
    public static let interval: TimeInterval = 24 * 60 * 60

    private let preferences: UpdatePreferences
    private let current: String
    private let fetcher: UpdateCheck.Fetcher
    private let now: @MainActor () -> Date
    private let scheduler: UpdateScheduling
    private let announce: @MainActor (UpdateOffer) -> Void
    private let withdraw: @MainActor (String) -> Void
    private let changed: @MainActor () -> Void
    private var watch: UpdatePreferences.Watch?
    private var checking = false

    /// `current`: the running version. `announce` posts the notification, `withdraw` takes one down
    /// by its id, and `changed` is called when the menu's row may have appeared or gone.
    public init(preferences: UpdatePreferences, current: String = Locations.version,
                fetcher: @escaping UpdateCheck.Fetcher = UpdateCheck.urlSession,
                now: @escaping @MainActor () -> Date = { Date() },
                scheduler: UpdateScheduling,
                announce: @escaping @MainActor (UpdateOffer) -> Void,
                withdraw: @escaping @MainActor (String) -> Void,
                changed: @escaping @MainActor () -> Void = {}) {
        self.preferences = preferences
        self.current = current
        self.fetcher = fetcher
        self.now = now
        self.scheduler = scheduler
        self.announce = announce
        self.withdraw = withdraw
        self.changed = changed
    }

    // MARK: The question

    /// Counts a launch of the menu bar app with its icon shown, until the question is answered.
    public func noteLaunch() {
        if preferences.automatic == nil { preferences.launches += 1 }
    }

    /// The question is due on the second launch, once, when permissions are set up (the caller
    /// says); a later launch asks if they were not.
    public var questionDue: Bool { preferences.automatic == nil && preferences.launches >= 2 }

    public var answered: Bool { preferences.automatic != nil }

    /// Stores the answer (or the switch in About) and starts or stops the schedule.
    public func setAutomatic(_ on: Bool) {
        preferences.automatic = on
        arm()
        changed()
    }

    // MARK: The schedule

    public var automatic: Bool { preferences.automatic == true }

    /// Starts listening for the switch (Settings writes it from another process) and arms the
    /// schedule when it is on. A reminder for a release this app has since caught up with is taken down.
    public func start() {
        watch = UpdatePreferences.Watch(preferences.defaults) { [weak self] in
            self?.arm()
            self?.changed()
        }
        if let latest = preferences.latest, !isNewer(latest.version) { withdraw(UpdateOffer(latest).notificationID) }
        arm()
    }

    /// Whether 24 hours have passed since the last request. A last request in the future (the
    /// clock was set back) counts as long ago.
    func isDue(_ date: Date) -> Bool {
        guard let last = preferences.lastCheck, last <= date else { return true }
        return date.timeIntervalSince(last) >= Self.interval
    }

    private func delay(_ date: Date) -> TimeInterval {
        guard let last = preferences.lastCheck, last <= date else { return 0 }
        return max(0, Self.interval - date.timeIntervalSince(last))
    }

    private func arm() {
        guard automatic else { scheduler.cancel(); return }
        scheduler.schedule(after: delay(now())) { [weak self] done in
            guard let self else { done(); return }
            Task { @MainActor in
                await self.check()
                done()
                self.arm()
            }
        }
    }

    /// What the system scheduler runs: one request if automatic checks are on and 24 hours have
    /// passed since the last, then the reminders. The time is recorded before the request, so a
    /// failure, or a quit during it, waits for the next window.
    public func check() async {
        guard automatic, !checking, isDue(now()) else { return }
        checking = true
        defer { checking = false }
        preferences.lastCheck = now()
        switch await UpdateCheck.fetchScheduled(etag: preferences.latest == nil ? nil : preferences.etag, fetcher: fetcher) {
        case .latest(let release, let etag):
            preferences.latest = release
            preferences.etag = etag
        case .notModified, .failed:
            break
        }
        remind()
    }

    // MARK: Reminders

    private func isNewer(_ version: UpdateCheck.Version) -> Bool {
        UpdateCheck.Version(current).map { version > $0 } ?? true
    }

    /// The release to offer: found by a check, newer than the running app, not skipped, and only
    /// while automatic checks are on.
    public var offer: UpdateOffer? {
        guard automatic, let latest = preferences.latest, isNewer(latest.version),
              preferences.skipped != latest.version else { return nil }
        return UpdateOffer(latest)
    }

    private func remind() {
        guard let offer, preferences.notified != offer.version else { return }
        preferences.notified = offer.version
        announce(offer)
        changed()
    }

    /// Skip This Version: the row and the reminders for this version go, and a newer version
    /// brings them back.
    public func skip() {
        guard let offer else { return }
        preferences.skipped = offer.version
        withdraw(offer.notificationID)
        changed()
    }
}

extension UpdateOffer {
    init(_ release: UpdateCheck.Release) { self.init(version: release.version, page: release.page) }
}
