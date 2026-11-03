import Foundation
import Testing

// General and the notices, read from their sources: the words docs/ui-language.md retires, the
// banner's colours, the Open buttons' labels, and that Use Last Working Config asks first.

@Suite struct GeneralPaneTests {
    private static let ui = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/PureMouseSettingsUI")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: ui.appending(path: name), encoding: .utf8)
    }

    private static let files = ["GeneralPane.swift", "Notices.swift", "Components.swift"]

    @Test func noRetiredWordsInGeneralOrTheBanners() throws {
        for file in Self.files {
            let text = try Self.source(file)
            for retired in ["Open Settings…", "PureMouse isn't running", "Not Allowed", "Open Login Items…", "Open Config\"",
                            "Restore Last Working", "Unknown While Off", "Needs the menu bar icon",
                            "Stopping returns", "Turning it off doesn't stop", "PureMouse Settings"] {
                #expect(!text.contains(retired), "\(file) says \(retired)")
            }
        }
    }

    /// General's PureMouse row is the pause switch (`AppModel.setPaused`, through `RunState`'s
    /// mapping, tested in BannerPlanTests), with Start only while off, and Open at login has no
    /// caption (#146). The row is read up to the low battery row, which follows it.
    @Test func thePureMouseRowPausesAndStartsAndOpenAtLoginHasNoCaption() throws {
        let general = try Self.source("GeneralPane.swift")
        let row = try #require(general.range(of: "private var runningRow").map { general[$0.lowerBound...] })
        let body = try #require(row.range(of: "/// The menu bar app posts the notifications").map { String(row[..<$0.lowerBound]) })
        #expect(body.contains("state.toggled(on)"))
        #expect(body.contains("model.setPaused("))
        #expect(body.contains(".accessibilityValue(state.word)"))
        #expect(body.contains(".toggleStyle(.switch)"))
        #expect(body.contains(#"Button("Start")"#))
        #expect(!body.contains("Stop"))
        #expect(general.contains(#"RowLabel("Open at login")"#))
        #expect(!general.contains(#"RowLabel("Open at login", help"#))
    }

    /// The notices below the PureMouse row leave out off and paused, which that row already shows.
    @Test func generalListsNoticesThroughThePlanThatLeavesOutTheRowsOwn() throws {
        #expect(try Self.source("GeneralPane.swift").contains("BannerPlan.generalItems(for:"))
    }

    /// No Stop button anywhere in Settings: no string literal in its sources starts "Stop".
    @Test func noStopButtonAnywhereInSettings() throws {
        let enumerator = FileManager.default.enumerator(at: Self.ui, includingPropertiesForKeys: nil)
        for file in (enumerator?.allObjects as? [URL] ?? []) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("\"Stop"), "\(file.lastPathComponent) has a Stop label")
        }
    }

    /// Hiding the icon keeps the menu process running without a status item, so the low battery
    /// switch is never disabled by it, and the update switch has no such dependency either.
    @Test func hidingTheIconDisablesNothing() throws {
        let general = try Self.source("GeneralPane.swift")
        let row = try #require(general.range(of: "private var lowBatteryRow").map { String(general[$0.lowerBound...]) })
        let body = String(row.prefix(1200))
        #expect(!body.contains("showsInMenuBar"), "the low battery row follows the icon")
        #expect(!body.contains(".disabled(needsIcon)"))
        let about = try Self.source("AboutPane.swift")
        #expect(!about.contains("showsInMenuBar"))
    }

    @Test func theBannerSetsNoColourTint() throws {
        let notices = try Self.source("Notices.swift")
        let banner = try #require(notices.range(of: "struct Banner<").map { String(notices[$0.lowerBound...]) })
        let body = try #require(banner.range(of: "/// A notice as a row").map { String(banner[..<$0.lowerBound]) })
        for tint in ["tint", "Color", ".yellow", ".red", ".green", ".orange"] {
            #expect(!body.contains(tint), "Banner uses \(tint)")
        }
        #expect(body.contains(".symbolRenderingMode(.multicolor)"))
    }

    @Test func theTwoOpenButtonsSayWhatTheyOpen() throws {
        let general = try Self.source("GeneralPane.swift")
        #expect(general.contains(#".accessibilityLabel("Open config file")"#))
        #expect(general.contains(#".accessibilityLabel("Open log")"#))
    }

    /// The only call that replaces the config file with the last working one is the confirming
    /// button of its dialog, a verb without the destructive style (docs/ui-design.md).
    @Test func useLastWorkingConfigAsksBeforeWriting() throws {
        let enumerator = FileManager.default.enumerator(at: Self.ui, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var calls: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            where line.contains("restoreLastWorking()") {
                calls.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(calls == [#"Button(UseLastWorkingConfirmation.button) { model.restoreLastWorking() }"#])
        let notices = try Self.source("Notices.swift")
        #expect(notices.contains(#"Button("Use Last Working Config…") { confirmingLastWorking = true }"#))
    }

    @Test func nothingInSettingsRegisters() throws {
        let enumerator = FileManager.default.enumerator(at: Self.ui, includingPropertiesForKeys: nil)
        for file in (enumerator?.allObjects as? [URL] ?? []) where file.pathExtension == "swift" {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("perform(.register)"), "\(file.lastPathComponent)")
        }
    }
}
