import Foundation
import Testing
@testable import PureMouseAppSupport

/// The daily update check: when it may run, what it sends, and the reminders it earns. The clock, the
/// fetcher and the scheduler are injected, so nothing here reaches GitHub or waits for time.
@MainActor
final class UpdateHarness {
    final class Scheduler: UpdateScheduling {
        var delays: [TimeInterval] = []
        var cancelled = 0
        var work: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
        func schedule(after delay: TimeInterval, work: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) {
            delays.append(delay)
            self.work = work
        }
        func cancel() { cancelled += 1; work = nil }
    }

    /// Everything the fetcher saw, and what it answers next.
    final class Network: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [(status: Int, body: String, etag: String?)] = []
    }

    let suite = "PureMouseUpdateTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: UpdatePreferences
    let scheduler = Scheduler()
    let network = Network()
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var announced: [UpdateOffer] = []
    var withdrawn: [String] = []
    var changes = 0

    init() {
        defaults = UserDefaults(suiteName: suite)!
        preferences = UpdatePreferences(defaults)
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    nonisolated static func release(_ version: String) -> String {
        #"{"tag_name": "v\#(version)", "html_url": "https://github.com/mblauberg/PureMouse/releases/tag/v\#(version)"}"#
    }

    func answer(_ status: Int = 200, version: String = "0.6.0", etag: String? = "\"abc\"") {
        network.answers.append((status, status == 200 ? Self.release(version) : "", etag))
    }

    /// A new `UpdateReminders` over the same preferences, as a relaunch is.
    func reminders(current: String = "0.5.0") -> UpdateReminders {
        let network = network
        let fetcher: UpdateCheck.Fetcher = { request in
            network.requests.append(request)
            guard !network.answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            let next = network.answers.removeFirst()
            var headers: [String: String] = [:]
            if let etag = next.etag { headers["ETag"] = etag }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: headers)!
            return (Data(next.body.utf8), response)
        }
        return UpdateReminders(preferences: preferences, current: current, fetcher: fetcher,
                               now: { [unowned self] in date }, scheduler: scheduler,
                               announce: { [unowned self] in announced.append($0) },
                               withdraw: { [unowned self] in withdrawn.append($0) },
                               changed: { [unowned self] in changes += 1 })
    }
}

@MainActor
@Suite struct UpdateRemindersTests {
    let h = UpdateHarness()

    // MARK: Asking once

    @Test func nothingIsAskedOnTheFirstLaunch() {
        let reminders = h.reminders()
        reminders.noteLaunch()
        #expect(!reminders.questionDue)
    }

    @Test func theQuestionIsDueOnTheSecondLaunchAndLater() {
        h.reminders().noteLaunch()
        let second = h.reminders()
        second.noteLaunch()
        #expect(second.questionDue)
        // Permissions were not set up on the second: it is due on the third.
        let third = h.reminders()
        third.noteLaunch()
        #expect(third.questionDue)
    }

    @Test func anAnsweredQuestionIsNeverDueAgainWhateverTheAnswer() {
        for answer in [true, false] {
            let harness = UpdateHarness()
            harness.reminders().noteLaunch()
            let second = harness.reminders()
            second.noteLaunch()
            second.setAutomatic(answer)
            for _ in 0..<3 {
                let later = harness.reminders()
                later.noteLaunch()
                #expect(!later.questionDue && later.answered)
            }
            #expect(harness.preferences.launches == 2)  // not counted once answered
        }
    }

    @Test func theSwitchInAboutAnswersTheQuestionToo() {
        h.preferences.automatic = true
        let reminders = h.reminders()
        reminders.noteLaunch()
        reminders.noteLaunch()
        #expect(!reminders.questionDue)
    }

    // MARK: Off means no request

    @Test func noRequestIsMadeUnansweredDeclinedOrSwitchedOff() async {
        for answer in [nil, false] as [Bool?] {
            let harness = UpdateHarness()
            harness.preferences.automatic = answer
            harness.answer()
            let reminders = harness.reminders()
            reminders.start()
            await reminders.check()
            #expect(harness.network.requests.isEmpty)
            #expect(harness.scheduler.delays.isEmpty && harness.scheduler.cancelled > 0)
            #expect(reminders.offer == nil)
        }
    }

    @Test func switchingOffStopsTheScheduleAndHidesTheOffer() async {
        h.answer()
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(reminders.offer?.version.text == "0.6.0")
        reminders.setAutomatic(false)
        #expect(reminders.offer == nil)
        #expect(h.scheduler.work == nil)
        h.date += 3 * 86_400
        await reminders.check()
        #expect(h.network.requests.count == 1)
    }

    // MARK: At most once every 24 hours

    @Test func aCheckIsDueAtOnceTheFirstTimeThenOnlyAfter24Hours() async {
        h.answer(); h.answer(etag: nil)
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        #expect(h.scheduler.delays == [0])
        await reminders.check()
        #expect(h.network.requests.count == 1)
        for hours in [0.0, 1, 12, 23.9] {
            h.date = Date(timeIntervalSince1970: 1_800_000_000 + hours * 3600)
            await reminders.check()
        }
        #expect(h.network.requests.count == 1)
        h.date = Date(timeIntervalSince1970: 1_800_000_000 + 24 * 3600)
        await reminders.check()
        #expect(h.network.requests.count == 2)
    }

    @Test func relaunchesAndWakesDoNotCheckAgainWithin24Hours() async {
        h.answer(); h.answer(304, etag: nil)
        let first = h.reminders()
        first.setAutomatic(true)
        await first.check()
        // Quit, relaunch 5 hours later; the schedule is armed for the 19 hours left.
        h.date += 5 * 3600
        h.scheduler.delays = []
        let second = h.reminders()
        second.start()
        #expect(h.scheduler.delays == [19 * 3600])
        // The system wakes it early, or the Mac wakes from sleep and runs it: still not due.
        await second.check()
        #expect(h.network.requests.count == 1)
        h.date += 19 * 3600
        await second.check()
        #expect(h.network.requests.count == 2)
    }

    @Test func aFailureWaitsForTheNextWindow() async {
        h.answer(500, etag: nil)
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()  // fails: GitHub answered 500
        #expect(h.network.requests.count == 1 && reminders.offer == nil)
        h.date += 3600
        await reminders.check()
        h.date += 23 * 3600 - 1
        await reminders.check()
        #expect(h.network.requests.count == 1)
        h.scheduler.delays = []
        h.date += 1
        h.answer()
        await reminders.check()
        #expect(h.network.requests.count == 2)
    }

    @Test func noConnectionIsAFailureToo() async {
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()  // the fetcher throws
        #expect(h.network.requests.count == 1)
        h.date += 60
        await reminders.check()
        #expect(h.network.requests.count == 1)
    }

    @Test func aClockSetBackWaitsAFullIntervalFromNowRatherThanChecking() async {
        h.preferences.automatic = true
        h.preferences.lastCheck = h.date.addingTimeInterval(10 * 86_400)
        h.answer()
        let reminders = h.reminders()
        await reminders.check()
        #expect(h.network.requests.isEmpty)
        #expect(h.preferences.lastCheck == h.date)  // rewritten to now
        reminders.start()
        #expect(h.scheduler.delays == [UpdateReminders.interval])
        h.date = h.date.addingTimeInterval(24 * 3600)
        await reminders.check()
        #expect(h.network.requests.count == 1)
    }

    @Test func theSwitchAnotherProcessWritesArmsAndCancelsTheSchedule() async {
        let reminders = h.reminders()
        reminders.start()
        #expect(h.scheduler.delays.isEmpty)
        h.preferences.automatic = true  // KVO delivers on the main actor, a turn later
        for _ in 0..<1000 where h.scheduler.delays.isEmpty { await Task.yield() }
        #expect(h.scheduler.delays == [0])
        let cancelled = h.scheduler.cancelled
        h.preferences.automatic = false
        for _ in 0..<1000 where h.scheduler.cancelled == cancelled { await Task.yield() }
        #expect(h.scheduler.cancelled > cancelled)
        withExtendedLifetime(reminders) {}
    }

    @Test func aNewerReleaseReplacesTheEarlierReminder() async {
        h.preferences.automatic = true
        h.answer(version: "0.6.0")
        await h.reminders().check()
        h.date = h.date.addingTimeInterval(25 * 3600)
        h.answer(version: "0.7.0", etag: "\"def\"")
        await h.reminders().check()
        #expect(h.announced.map(\.version.text) == ["0.6.0", "0.7.0"])
        #expect(h.withdrawn == ["update.0.6.0"])
    }

    @Test func turningTheChecksOffTakesTheReminderDown() async {
        h.answer(version: "0.6.0")
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(h.announced.count == 1)
        reminders.setAutomatic(false)
        #expect(h.withdrawn.last == "update.0.6.0")
        #expect(reminders.offer == nil)
    }

    @Test func theScheduleIsRearmedForTheNextWindowAfterACheck() async {
        h.answer()
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        let work = h.scheduler.work
        var finished = false
        work?({ finished = true })
        for _ in 0..<1000 where !finished { await Task.yield() }
        #expect(finished)
        #expect(h.network.requests.count == 1)
        #expect(h.scheduler.delays == [0, 24 * 3600])
    }

    // MARK: The request

    @Test func theRequestRefusesConstrainedAndExpensiveNetworksAndSendsTheKnownETag() async throws {
        h.answer(version: "0.6.0", etag: "\"v1\"")
        h.answer(304, etag: nil)
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        let first = try #require(h.network.requests.first)
        #expect(!first.allowsConstrainedNetworkAccess && !first.allowsExpensiveNetworkAccess)
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(first.url == UpdateCheck.endpoint && first.httpMethod == "GET")
        h.date += 86_400
        await reminders.check()
        let second = try #require(h.network.requests.last)
        #expect(second.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(!second.allowsConstrainedNetworkAccess && !second.allowsExpensiveNetworkAccess)
    }

    @Test func theOnDemandRequestIsUnchanged() {
        let request = UpdateCheck.request()
        #expect(request.allowsConstrainedNetworkAccess && request.allowsExpensiveNetworkAccess)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.timeoutInterval == 8)
    }

    @Test func aNotModifiedAnswerKeepsTheReleaseAndIsNotAFailureOrANewNotification() async {
        h.answer(version: "0.6.0", etag: "\"v1\"")
        h.answer(304, etag: nil)
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        h.date += 86_400
        await reminders.check()
        #expect(reminders.offer?.version.text == "0.6.0")
        #expect(h.announced.count == 1)
        #expect(h.preferences.etag == "\"v1\"")
    }

    @Test func aNotModifiedAnswerWithNoReleaseOnRecordSendsNoETag() async {
        h.preferences.automatic = true
        h.preferences.etag = "\"stale\""
        h.answer(version: "0.6.0")
        await h.reminders().check()
        #expect(h.network.requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func aMalformedBodyIsAFailureNotAnUpdate() async {
        h.preferences.automatic = true
        h.network.answers.append((200, "{}", nil))
        let reminders = h.reminders()
        await reminders.check()
        #expect(reminders.offer == nil && h.announced.isEmpty)
    }

    // MARK: Reminders

    @Test func aNewerReleaseIsAnnouncedOncePerVersion() async {
        h.answer(version: "0.6.0")
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(h.announced.map(\.title) == ["PureMouse 0.6.0 is available"])
        #expect(h.announced.first?.page.absoluteString == "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")
        // A later check, and a relaunch, find the same release: no second notification.
        h.date += 86_400
        h.answer(version: "0.6.0")
        await reminders.check()
        h.date += 86_400
        h.answer(version: "0.6.0")
        let relaunched = h.reminders()
        await relaunched.check()
        #expect(h.announced.count == 1)
        // A newer one is a new notification.
        h.date += 86_400
        h.answer(version: "0.6.1")
        await relaunched.check()
        #expect(h.announced.map(\.version.text) == ["0.6.0", "0.6.1"])
    }

    @Test func theRowStaysUntilTheRunningVersionIsAtLeastTheOffered() async {
        h.answer(version: "0.6.0")
        let reminders = h.reminders(current: "0.5.0")
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(reminders.offer?.menuTitle == "Update to 0.6.0…")
        #expect(h.reminders(current: "0.5.9").offer != nil)
        #expect(h.reminders(current: "0.6.0").offer == nil)
        #expect(h.reminders(current: "0.7.0").offer == nil)
    }

    @Test func aReleaseNoNewerThanTheRunningOneIsNotOffered() async {
        h.answer(version: "0.5.0")
        let reminders = h.reminders(current: "0.5.0")
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(reminders.offer == nil && h.announced.isEmpty)
    }

    @Test func updatingTakesDownTheReminderOnTheNextStart() async {
        h.answer(version: "0.6.0")
        let reminders = h.reminders(current: "0.5.0")
        reminders.setAutomatic(true)
        await reminders.check()
        h.reminders(current: "0.6.0").start()
        #expect(h.withdrawn == ["update.0.6.0"])
    }

    @Test func skippingHidesTheRowAndTheNotificationForThatVersionOnly() async {
        h.answer(version: "0.6.0")
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        await reminders.check()
        reminders.skip()
        #expect(reminders.offer == nil)
        #expect(h.withdrawn == ["update.0.6.0"])
        // The same release found again, even after a relaunch, stays quiet.
        h.preferences.notified = nil
        h.date += 86_400
        h.answer(version: "0.6.0")
        let relaunched = h.reminders()
        await relaunched.check()
        #expect(relaunched.offer == nil && h.announced.count == 1)
        // The next version is offered and announced.
        h.date += 86_400
        h.answer(version: "0.6.1")
        await relaunched.check()
        #expect(relaunched.offer?.version.text == "0.6.1")
        #expect(h.announced.map(\.version.text) == ["0.6.0", "0.6.1"])
    }

    @Test func skippingWithNothingOfferedDoesNothing() {
        let reminders = h.reminders()
        reminders.setAutomatic(true)
        reminders.skip()
        #expect(h.preferences.skipped == nil && h.withdrawn.isEmpty)
    }

    @Test func aVersionNotARealNumberCountsAsOlderThanAnyRelease() async {
        h.answer(version: "0.1.0")
        let reminders = h.reminders(current: "dev")
        reminders.setAutomatic(true)
        await reminders.check()
        #expect(reminders.offer != nil)
    }

    // MARK: Stored state

    @Test func theStoredStateRoundTripsAndKeepsOnlyHttpsPages() {
        let release = UpdateCheck.Release(version: UpdateCheck.Version("1.2.3")!, page: URL(string: "https://example.com/r")!)
        h.preferences.latest = release
        #expect(h.preferences.latest == release)
        h.defaults.set("http://example.com/r", forKey: "UpdatesLatestPage")
        #expect(h.preferences.latest == nil)
        h.preferences.lastCheck = Date(timeIntervalSince1970: 5)
        #expect(h.preferences.lastCheck == Date(timeIntervalSince1970: 5))
        h.preferences.lastCheck = nil
        #expect(h.defaults.object(forKey: "UpdatesLastCheck") == nil)
    }

    @Test func theNotificationsTextFollowsTheUILanguage() {
        let offer = UpdateOffer(version: UpdateCheck.Version("v1.2.3")!, page: URL(string: "https://example.com")!)
        #expect(offer.title == "PureMouse 1.2.3 is available")
        #expect(offer.body == "Click to read what's new.")
        #expect(offer.menuTitle == "Update to 1.2.3…")
        #expect(UpdateOffer.skipTitle == "Skip This Version")
        #expect(UpdateQuestion.title == "Check for updates automatically?")
        #expect(UpdateQuestion.accept == "Check Automatically" && UpdateQuestion.decline == "Don't Check")
    }
}

@Suite struct UpdateCheckScheduledTests {
    private func respond(_ status: Int, _ body: String, etag: String? = nil) -> UpdateCheck.Fetcher {
        { request in
            var headers: [String: String] = [:]
            if let etag { headers["ETag"] = etag }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    @Test func answersAreSortedIntoNotModifiedLatestAndFailed() async {
        let body = UpdateHarness.release("0.6.0")
        #expect(await UpdateCheck.fetchScheduled(etag: "x", fetcher: respond(304, "")) == .notModified)
        let latest = await UpdateCheck.fetchScheduled(etag: nil, fetcher: respond(200, body, etag: "\"e\""))
        #expect(latest == .latest(UpdateCheck.parse(Data(body.utf8))!, etag: "\"e\""))
        #expect(await UpdateCheck.fetchScheduled(etag: nil, fetcher: respond(403, body)) == .failed)
        #expect(await UpdateCheck.fetchScheduled(etag: nil, fetcher: respond(200, "nope")) == .failed)
        #expect(await UpdateCheck.fetchScheduled(etag: nil, fetcher: { _ in throw URLError(.timedOut) }) == .failed)
    }

    @Test func theOnDemandCheckStillOnlyTrustsA200() async {
        let body = UpdateHarness.release("0.6.0")
        if case .available(let release) = await UpdateCheck.fetch(current: "0.5.0", fetcher: respond(200, body)) {
            #expect(release.version.text == "0.6.0")
        } else {
            Issue.record("expected an update")
        }
        #expect(await UpdateCheck.fetch(current: "0.5.0", fetcher: respond(304, "")) == .failed)
        #expect(await UpdateCheck.fetch(current: "0.6.0", fetcher: respond(200, body)) == .upToDate)
    }
}

@Suite struct UpdateCheckParseTests {
    private func body(page: String) -> Data {
        Data(#"{"tag_name": "v0.6.0", "html_url": "\#(page)"}"#.utf8)
    }

    @Test func onlyThisProjectsReleasePagesAreAccepted() {
        #expect(UpdateCheck.parse(body(page: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")) != nil)
        for hostile in ["https://evil.example/mblauberg/PureMouse/releases/tag/v0.6.0",
                        "https://github.com.evil.example/mblauberg/PureMouse/releases/tag/v0.6.0",
                        "https://evil@github.com/mblauberg/PureMouse/releases/tag/v0.6.0",
                        "https://github.com:8443/mblauberg/PureMouse/releases/tag/v0.6.0",
                        "https://github.com/someone/else/releases/tag/v0.6.0",
                        "https://github.com/mblauberg/PureMouse",
                        "http://github.com/mblauberg/PureMouse/releases/tag/v0.6.0",
                        "file:///etc/passwd"] {
            #expect(UpdateCheck.parse(body(page: hostile)) == nil, "\(hostile)")
        }
    }
}

@Suite struct UpdatePreferencesWatchTests {
    /// The About pane's switch is written by another process; `defaults` stands in for it.
    @Test(.timeLimit(.minutes(1))) @MainActor func theMenuHearsTheSwitchAnotherProcessWrites() async throws {
        let suite = "PureMouseUpdateWatch-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (heard, ear) = AsyncStream<Void>.makeStream()
        let watch = UpdatePreferences.Watch(UserDefaults(suiteName: suite)!) { ear.yield() }
        var events = heard.makeAsyncIterator()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", suite, UpdatePreferences.automaticKey, "-bool", "true"]
        try process.run()
        process.waitUntilExit()
        _ = await events.next()
        #expect(UpdatePreferences(UserDefaults(suiteName: suite)!).automatic == true)
        withExtendedLifetime(watch) {}
    }
}
