import Foundation
import PureMouseAppSupport
import Testing
@testable import PureMouseSettingsUI

// The support link is the only mention of sponsorship in the app: one Link in the About pane,
// and the URL is written once, in its constant.

@Suite struct AboutLinks {
    private static let sponsorsURL = "github.com/sponsors/mblauberg"

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func theAboutPaneHasOneSupportLinkToSponsors() throws {
        let about = try String(contentsOf: Self.sources.appending(path: "PureMouseSettingsUI/AboutPane.swift"), encoding: .utf8)
        // `link(_:_:)` draws each as a plain button with a 20 pt target (a `Link` is its text's height).
        let links = about.components(separatedBy: " link(\"").count - 1
        let sponsorLinks = about.components(separatedBy: ", Links.sponsors)").count - 1
        #expect(sponsorLinks == 1)
        #expect(links == 4)
        #expect(about.contains(#"link("Support PureMouse", Links.sponsors)"#))
    }

    @Test func theSponsorsURLIsWrittenOnlyOnce() throws {
        let files = try Self.swiftFiles()
        let hits = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(Self.sponsorsURL) }
        #expect(hits.map(\.lastPathComponent) == ["SettingsPane+UI.swift"])
    }

    @Test func noOtherSponsorOrSupportTextAppearsInStrings() throws {
        // A string literal line that mentions sponsors or a standalone "support" word is a
        // user-visible mention. "Application Support" is the data folder, not a mention.
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                guard line.contains("\""), !line.contains(Self.sponsorsURL),
                      !line.contains("Application Support") else { continue }
                let words = line.lowercased().split { !$0.isLetter }.map(String.init)
                if words.contains("sponsor") || words.contains("sponsors") || words.contains("support") {
                    offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        let allowed = offenders.filter { $0.contains("Support PureMouse") }
        #expect(offenders.count == allowed.count, "\(offenders)")
    }

    @Test func theAboutPaneUsesNoFixedFontSize() throws {
        let about = try String(contentsOf: Self.sources.appending(path: "PureMouseSettingsUI/AboutPane.swift"), encoding: .utf8)
        #expect(!about.contains(".system(size:"))
    }

    @Test func theAboutPaneLeadsWithVersionAndUpdatesBeforeLinksAndFootnote() throws {
        let about = try String(contentsOf: Self.sources.appending(path: "PureMouseSettingsUI/AboutPane.swift"), encoding: .utf8)
        let order = ["Image(nsImage:", #"Text("PureMouse")"#, #"Text("Version "#, "UpdateRow()",
                     #"link("GitHub""#, "No account, no telemetry.", "Not affiliated with Logitech."]
        let positions = try order.map { try #require(about.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
    }

    /// The switch's position in the update row is a layout fact, so it is read from the source; what it
    /// does is tested below.
    @Test func theAutomaticSwitchSitsBetweenTheButtonAndTheOutcome() throws {
        let about = try String(contentsOf: Self.sources.appending(path: "PureMouseSettingsUI/AboutPane.swift"), encoding: .utf8)
        let button = try #require(about.range(of: #"Button(checking ? "Checking…" : "Check for Updates")"#)).lowerBound
        let toggle = try #require(about.range(of: #"Toggle("Check for updates automatically""#)).lowerBound
        let outcome = try #require(about.range(of: "switch outcome")).lowerBound
        #expect(button < toggle && toggle < outcome)
        #expect(about.contains("The network is used only to check for and download updates."))
    }
}

@MainActor
private final class RecordingScheduler: UpdateScheduling {
    var delays: [TimeInterval] = []
    var cancelled = 0
    func schedule(after delay: TimeInterval, work: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) { delays.append(delay) }
    func cancel() { cancelled += 1 }
}

/// What the switch does, with the menu app's side of it: the switch writes the answer and makes no
/// request; the menu app hears the write, arms or cancels its schedule, and takes the reminder down.
@MainActor
@Suite struct AboutSwitchTests {
    @Test func theSwitchMakesNoRequestAndTheMenuHearsIt() async {
        let suite = "PureMouseAboutSwitch-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let preferences = UpdatePreferences(UserDefaults(suiteName: suite)!)
        let requests = Requests()
        let scheduler = RecordingScheduler()
        var withdrawn: [String] = []
        let menu = UpdateReminders(
            preferences: preferences, current: "0.5.0",
            fetcher: { _ in requests.count += 1; throw URLError(.cancelled) },
            scheduler: scheduler, announce: { _ in }, withdraw: { withdrawn.append($0) })
        menu.start()
        #expect(scheduler.delays.isEmpty)
        let about = AutomaticUpdates(preferences: preferences)
        #expect(!about.isOn)

        about.set(true)
        for _ in 0..<1000 where scheduler.delays.isEmpty { await Task.yield() }
        #expect(about.isOn && scheduler.delays == [0])  // armed, not run

        preferences.notified = [UpdateCheck.Version("0.6.0")!]
        let cancelled = scheduler.cancelled
        about.set(false)
        for _ in 0..<1000 where scheduler.cancelled == cancelled { await Task.yield() }
        #expect(!about.isOn && scheduler.cancelled > cancelled)
        #expect(withdrawn.last == "update.0.6.0")
        #expect(requests.count == 0)
    }

    @Test func withoutTheMenuAppsDefaultsTheSwitchIsOffAndHarmless() {
        let about = AutomaticUpdates(preferences: nil)
        about.set(true)
        #expect(!about.isOn)
    }

    @MainActor @Test func updateAndRelaunchIsARequestToTheMenuAppAndTheHelperInstallsNothing() {
        let preferences = UpdatePreferences(UserDefaults(suiteName: "pm-about-\(UUID().uuidString)")!)
        var yielded = 0
        let request = InstallRequest(preferences: preferences, menuIsRunning: { true }, yieldFocus: { yielded += 1 })
        let release = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!,
                                          page: URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")!)
        #expect(request.isOffered)
        request.ask(for: release)
        #expect(preferences.installRequest == release && yielded == 1)
    }

    @MainActor @Test func theButtonIsOfferedOnlyWhereTheMenuAppCanHearIt() {
        let preferences = UpdatePreferences(UserDefaults(suiteName: "pm-about-\(UUID().uuidString)")!)
        let release = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: URL(string: "https://example.com")!)
        let hidden = InstallRequest(preferences: preferences, menuIsRunning: { false }, yieldFocus: {})
        #expect(!hidden.isOffered)
        hidden.ask(for: release)
        #expect(preferences.installRequest == nil)
        let none = InstallRequest(preferences: nil, menuIsRunning: { true }, yieldFocus: {})
        #expect(!none.isOffered)
        none.ask(for: release)
    }

    @MainActor @Test func aSecondRequestWhileOneIsUnderWayIsNotSent() {
        let preferences = UpdatePreferences(UserDefaults(suiteName: "pm-about-\(UUID().uuidString)")!)
        preferences.installStatus = "Updating to 0.6.0…"
        let request = InstallRequest(preferences: preferences, menuIsRunning: { true }, yieldFocus: {})
        #expect(request.inProgress)
        request.ask(for: UpdateCheck.Release(version: UpdateCheck.Version("0.7.0")!, page: URL(string: "https://example.com")!))
        #expect(preferences.installRequest == nil && preferences.installStatus == "Updating to 0.6.0…")
    }

    @MainActor @Test func aFailureStaysAskableAgainAndTheOldReasonIsClearedWithTheNextRequest() {
        let preferences = UpdatePreferences(UserDefaults(suiteName: "pm-about-\(UUID().uuidString)")!)
        preferences.installStatus = "The download doesn't match its checksum"
        let request = InstallRequest(preferences: preferences, menuIsRunning: { true }, yieldFocus: {})
        #expect(!request.inProgress)
        let release = UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: URL(string: "https://example.com")!)
        request.ask(for: release)
        #expect(preferences.installStatus == nil && preferences.installRequest == release)
    }

    final class Requests: @unchecked Sendable { var count = 0 }
}
