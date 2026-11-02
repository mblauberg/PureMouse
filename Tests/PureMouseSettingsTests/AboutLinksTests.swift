import Foundation
import Testing

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

    @Test func theAutomaticSwitchSitsInTheUpdateRowAndMakesNoRequestOfItsOwn() throws {
        let about = try String(contentsOf: Self.sources.appending(path: "PureMouseSettingsUI/AboutPane.swift"), encoding: .utf8)
        let button = try #require(about.range(of: #"Button(checking ? "Checking…" : "Check for Updates")"#)).lowerBound
        let toggle = try #require(about.range(of: #"Toggle("Check for updates automatically""#)).lowerBound
        let outcome = try #require(about.range(of: "switch outcome")).lowerBound
        #expect(button < toggle && toggle < outcome)
        // The only request this pane starts is the one the button's `check()` makes.
        #expect(about.components(separatedBy: "UpdateCheck.fetch").count - 1 == 1)
        #expect(!about.contains("fetchScheduled") && !about.contains("UpdateReminders("))
        #expect(about.contains("The network is used only to check for updates."))
    }
}
