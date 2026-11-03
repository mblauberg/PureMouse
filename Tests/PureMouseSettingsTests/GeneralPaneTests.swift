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
                            "Restore Last Working", "Unknown While Off", "Needs the menu bar icon"] {
                #expect(!text.contains(retired), "\(file) says \(retired)")
            }
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
