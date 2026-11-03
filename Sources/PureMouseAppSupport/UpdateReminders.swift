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
    public var notificationID: String { Self.notificationID(for: version) }
    static func notificationID(for version: UpdateCheck.Version) -> String { "update.\(version.text)" }
    /// The menu row.
    public var menuTitle: String { "Update to \(version.text)…" }
    public static let skipTitle = "Skip This Version"
    public static let viewTitle = "View Release"

    /// The menu row while the update downloads and is checked.
    public var installingTitle: String { "Updating to \(version.text)…" }

    /// The alert the row opens: nothing is downloaded until it is answered.
    public var confirmTitle: String { "Update to PureMouse \(version.text)?" }
    public static let confirmMessage = "PureMouse downloads the update from GitHub, checks that it is signed by the same certificate as this copy, replaces this copy and opens again."
    public static let confirmAccept = "Update and Relaunch"
    public static let confirmDecline = "Cancel"
    public static let relaunchFailed = (title: "PureMouse is updated.", body: "Open it from Applications to finish.")
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
    private static let skippedKey = "UpdatesSkippedVersions"
    private static let notifiedKey = "UpdatesNotifiedVersions"
    static let requestVersionKey = "UpdatesInstallRequestVersion"
    private static let requestPageKey = "UpdatesInstallRequestPage"
    static let statusKey = "UpdatesInstallStatus"

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

    /// Settings' About pane asks the menu bar app, which owns installing (ADR 22), to install this
    /// release: the menu app asks the person, hears the write, and clears it. Any other process of
    /// the user could write it too, which is why the menu app asks, and checks the release page and
    /// the version, and the installer checks the signature.
    public var installRequest: UpdateCheck.Release? {
        get {
            guard let text = defaults.string(forKey: Self.requestVersionKey), let version = UpdateCheck.Version(text),
                  let page = defaults.string(forKey: Self.requestPageKey).flatMap(URL.init(string:)) else { return nil }
            return UpdateCheck.Release(version: version, page: page)
        }
        nonmutating set {
            set(newValue?.page.absoluteString, Self.requestPageKey)
            set(newValue?.version.text, Self.requestVersionKey)   // last: this is the key that is watched
        }
    }

    /// What the menu bar app is doing with the update it was asked for, in one line for About to
    /// show: "Updating to 0.6.0…" while it runs, the reason when it did not install. nil otherwise.
    public var installStatus: String? {
        get { defaults.string(forKey: Self.statusKey) }
        nonmutating set { set(newValue, Self.statusKey) }
    }

    /// How many versions each list below keeps; the oldest are forgotten first.
    public static let remembered = 16

    /// The versions whose reminders the person turned off, exactly those and no others.
    public var skipped: [UpdateCheck.Version] {
        get { versions(Self.skippedKey) }
        nonmutating set { store(newValue, Self.skippedKey) }
    }

    /// The versions a notification was posted for, so none is announced twice, even if the latest
    /// release goes 0.6.0, 0.7.0, 0.6.0.
    public var notified: [UpdateCheck.Version] {
        get { versions(Self.notifiedKey) }
        nonmutating set { store(newValue, Self.notifiedKey) }
    }

    private func versions(_ key: String) -> [UpdateCheck.Version] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UpdateCheck.Version.init)
    }

    private func store(_ versions: [UpdateCheck.Version], _ key: String) {
        var kept: [UpdateCheck.Version] = []
        for version in versions where !kept.contains(version) { kept.append(version) }
        if kept.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(kept.suffix(Self.remembered).map(\.text), forKey: key) }
    }

    private func set(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Calls `changed` each time the answer is written, from this process or another (Settings'
    /// switch, for as long as it is kept). Key-value observing hears another process's writes;
    /// `UserDefaults.didChangeNotification` does not.
    public final class Watch: NSObject {
        /// What can be watched.
        public enum Key { case automatic, installRequest, installStatus }

        private let defaults: UserDefaults
        private let changed: @MainActor () -> Void
        private let keys: [String]

        public init(_ defaults: UserDefaults, _ key: Key = .automatic, changed: @escaping @MainActor () -> Void) {
            self.defaults = defaults
            self.changed = changed
            switch key {
            case .automatic: keys = [UpdatePreferences.automaticKey]
            case .installRequest: keys = [UpdatePreferences.requestVersionKey]
            case .installStatus: keys = [UpdatePreferences.statusKey]
            }
            super.init()
            for key in keys { defaults.addObserver(self, forKeyPath: key, context: nil) }
        }

        deinit { for key in keys { defaults.removeObserver(self, forKeyPath: key) } }

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
        withdrawStale()
        arm()
    }

    /// A last request in the future (the clock was set back) is rewritten to now, so a full
    /// interval is waited from here, as Sparkle does: the 24 hours between requests hold whatever the clock does.
    private func normaliseLastCheck(_ date: Date) {
        if let last = preferences.lastCheck, last > date { preferences.lastCheck = date }
    }

    /// Whether 24 hours have passed since the last request.
    func isDue(_ date: Date) -> Bool {
        normaliseLastCheck(date)
        guard let last = preferences.lastCheck else { return true }
        return date.timeIntervalSince(last) >= Self.interval
    }

    private func delay(_ date: Date) -> TimeInterval {
        normaliseLastCheck(date)
        guard let last = preferences.lastCheck else { return 0 }
        return max(0, Self.interval - date.timeIntervalSince(last))
    }

    private func arm() {
        guard automatic else {
            scheduler.cancel()
            withdrawStale()
            return
        }
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

    /// The release to offer: found by a check, newer than the running app, not one the person
    /// skipped (that version only), and only while automatic checks are on.
    public var offer: UpdateOffer? {
        guard automatic, let latest = preferences.latest, isNewer(latest.version),
              !preferences.skipped.contains(latest.version) else { return nil }
        return UpdateOffer(latest)
    }

    private func remind() {
        defer { withdrawStale() }
        // A version is announced once, even if the latest release goes 0.6.0, 0.7.0, 0.6.0.
        guard let offer, !preferences.notified.contains(offer.version) else { return }
        preferences.notified += [offer.version]
        announce(offer)
        changed()
    }

    /// Takes down the notification of every version notified but not on offer: an older release
    /// replaced by a newer one, a version skipped or installed, a rollback's higher version, or
    /// all of them while checks are off. Taking down one that is not delivered does nothing.
    private func withdrawStale() {
        let offered = offer?.version
        for version in preferences.notified where version != offered {
            withdraw(UpdateOffer.notificationID(for: version))
        }
    }

    /// Skip This Version: the row and the reminders for this version go, and a newer version
    /// brings them back.
    public func skip() {
        guard let offer else { return }
        preferences.skipped += [offer.version]
        if !preferences.notified.contains(offer.version) { withdraw(offer.notificationID) }  // no record, maybe delivered
        withdrawStale()
        changed()
    }
}

extension UpdateOffer {
    init(_ release: UpdateCheck.Release) { self.init(version: release.version, page: release.page) }
}
