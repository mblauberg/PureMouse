import AppKit
import Foundation
import PureMouseAppSupport
import PureMouseKit
import Testing
@testable import PureMouseSettingsUI

private func isISODate(_ text: String) -> Bool {
    text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        && ISO8601DateFormatter().date(from: text + "T00:00:00Z") != nil
}

@Suite struct ActionPackCatalogTests {
    @Test func bundledCatalogueLoadsAndValidates() throws {
        let catalog = ActionPackCatalog.shared
        #expect(!catalog.data.packs.isEmpty)
        try catalog.validate()
    }

    @Test func acceptance1CoversRequiredPacksAndCounts() throws {
        let catalog = ActionPackCatalog.shared
        let expectedBundles = [
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.adobe.Photoshop",
            "com.figma.Desktop",
            "com.apple.FinalCut",
            "com.microsoft.Excel",
            "com.microsoft.Powerpoint",
            "com.microsoft.Word",
            "com.microsoft.VSCode",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.microsoft.edgemac",
        ]

        for bundleId in expectedBundles {
            let pack = catalog.pack(for: bundleId)
            #expect(pack != nil, "Expected pack for \(bundleId)")
            guard let pack else { continue }
            #expect(pack.actions.count >= 6, "Pack \(pack.name) has only \(pack.actions.count) actions, expected at least 6")
        }

        // Teams alias check
        #expect(catalog.pack(for: "com.microsoft.teams")?.name == "Microsoft Teams")

        // Inspect all actions across the catalogue
        var allIds = Set<String>()
        for pack in catalog.data.packs {
            for action in pack.actions {
                #expect(!allIds.contains(action.id), "Duplicate action id: \(action.id)")
                allIds.insert(action.id)

                #expect(!action.label.isEmpty)
                #expect(!action.label.lowercased().contains("toggle"), "Label '\(action.label)' should not use 'toggle' per ui-language.md")
                #expect(!action.category.isEmpty)
                #expect(!action.sourceURL.isEmpty)
                #expect(URL(string: action.sourceURL) != nil, "Invalid source URL: \(action.sourceURL)")
                #expect(isISODate(action.verifiedDate), "Verified date is not YYYY-MM-DD: \(action.verifiedDate)")
                #expect(action.sourceURL.hasPrefix("https://"), "Source URL is not https: \(action.sourceURL)")
                if let symbol = action.symbol {
                    #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "No SF Symbol \(symbol)")
                }
                #expect(Shortcut.isValid(action.payload) || ActionCatalog.groups.flatMap(\.names).contains(action.payload),
                        "Payload does not parse: \(action.payload)")

                for bId in action.bundleIDs {
                    #expect(pack.bundleIDs.contains(bId), "Action bundleId \(bId) not in pack bundleIds \(pack.bundleIDs)")
                }
            }
        }
    }

    @Test func validationRequiresHTTPSSources() {
        let entries = (1...6).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test", payload: "cmd+\(i)",
                            sourceURL: i == 6 ? "http://example.com" : "https://example.com", verifiedDate: "2026-11-04")
        }
        let data = ActionCatalogData(packs: [ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)])
        #expect(throws: ActionPackCatalog.ValidationError.invalidSourceURL(actionID: "act6", url: "http://example.com")) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func theCatalogueLoadsFromTheBundleItIsGiven() throws {
        // The Settings helper has the file in Contents/Resources; the source file is the test fallback.
        let bundleURL = FileManager.default.temporaryDirectory.appending(path: "packs-\(UUID().uuidString).bundle")
        let resources = bundleURL.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Data(#"{"packs":[]}"#.utf8).write(to: resources.appending(path: "ActionPacks.json"))
        let bundle = try #require(Bundle(url: bundleURL))
        #expect(ActionPackCatalog(bundle: bundle).packs.isEmpty)
        #expect(!ActionPackCatalog(bundle: Bundle.main).packs.isEmpty)
    }

    @Test func validationRejectsDuplicateIds() {
        let entry1 = ActionPackEntry(id: "dup", bundleIDs: ["com.test"], label: "Action 1", category: "Test",
                                     payload: "cmd+1", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        let entry2 = ActionPackEntry(id: "dup", bundleIDs: ["com.test"], label: "Action 2", category: "Test",
                                     payload: "cmd+2", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        let dummy = (3...6).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: [entry1, entry2] + dummy)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func validationRejectsUnknownBundleIds() {
        let entries = (1...6).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.unknown"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func validationRejectsInvalidPayloads() {
        var entries = (1...5).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        entries.append(ActionPackEntry(id: "act6", bundleIDs: ["com.test"], label: "Action 6", category: "Test",
                                       payload: "invalid_key_combo@@@", sourceURL: "https://example.com", verifiedDate: "2026-11-04"))
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func validationRejectsPacksWithFewerThanSixActions() {
        let entries = (1...5).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func validationRejectsMissingSourceOrDate() {
        var entries = (1...5).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        entries.append(ActionPackEntry(id: "act6", bundleIDs: ["com.test"], label: "Action 6", category: "Test",
                                       payload: "cmd+6", sourceURL: "", verifiedDate: "2026-11-04"))
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func validationRejectsBrokenPairedOpposite() {
        var entries = (1...5).map { i in
            ActionPackEntry(id: "act\(i)", bundleIDs: ["com.test"], label: "Action \(i)", category: "Test",
                            payload: "cmd+\(i)", sourceURL: "https://example.com", verifiedDate: "2026-11-04")
        }
        entries.append(ActionPackEntry(id: "act6", bundleIDs: ["com.test"], label: "Action 6", category: "Test",
                                       payload: "cmd+6", sourceURL: "https://example.com", verifiedDate: "2026-11-04",
                                       pairedOpposite: "nonexistent_action_id"))
        let pack = ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: entries)
        let data = ActionCatalogData(packs: [pack])

        #expect(throws: ActionPackCatalog.ValidationError.self) {
            try ActionPackCatalog.validate(data)
        }
    }

    @Test func lookupMatchesPacksAndActions() {
        let catalog = ActionPackCatalog.shared
        let zoom = catalog.pack(for: "us.zoom.xos")
        #expect(zoom != nil)

        // Matching action for Zoom mute: cmd+shift+a
        let muteAction = catalog.action(matching: .keys("cmd+shift+a"), in: "us.zoom.xos")
        #expect(muteAction?.id == "zoom.muteAudio")
        #expect(muteAction?.label == "Mute or Unmute Microphone")

        // Alternate modifier order also parses to same shortcut
        let muteAction2 = catalog.action(matching: .keys("shift+cmd+a"), in: "us.zoom.xos")
        #expect(muteAction2?.id == "zoom.muteAudio")

        // Nonexistent action in Zoom
        let unknown = catalog.action(matching: .keys("ctrl+alt+shift+9"), in: "us.zoom.xos")
        #expect(unknown == nil)

        // App without a pack
        let noPackAction = catalog.action(matching: .keys("cmd+shift+a"), in: "com.random.unsupported")
        #expect(noPackAction == nil)
    }

    @Test func thumbWheelPairsForSupportedApps() {
        let catalog = ActionPackCatalog.shared
        // Photoshop has brush size pair
        let psPairs = catalog.pairs(for: "com.adobe.Photoshop")
        #expect(psPairs.contains { $0.label == "Brush Size" })

        let brushPair = psPairs.first { $0.label == "Brush Size" }
        #expect(brushPair?.left.id == "photoshop.decreaseBrushSize")
        #expect(brushPair?.right.id == "photoshop.increaseBrushSize")

        // Matching pair from left and right actions
        let matchedPair = catalog.pair(matchingLeft: .keys("["), right: .keys("]"), in: "com.adobe.Photoshop")
        #expect(matchedPair?.label == "Brush Size")

        // Reversed does not match normal pair
        let nonMatched = catalog.pair(matchingLeft: .keys("]"), right: .keys("["), in: "com.adobe.Photoshop")
        #expect(nonMatched == nil)

        // Final Cut Pro pairs: turning left zooms out
        let fcpPairs = catalog.pairs(for: "com.apple.FinalCut")
        let fcpZoom = fcpPairs.first { $0.label == "Zoom Timeline" }
        #expect(fcpZoom?.left.id == "finalcut.zoomOut" && fcpZoom?.right.id == "finalcut.zoomIn")

        // Excel pairs
        let excelPairs = catalog.pairs(for: "com.microsoft.Excel")
        #expect(excelPairs.contains { $0.label == "Switch Sheets" })

        // VS Code pairs: its own shortcut list names folding, not a positional editor switch
        let vsPairs = catalog.pairs(for: "com.microsoft.VSCode")
        #expect(vsPairs.map(\.label) == ["Fold Code"])
        #expect(vsPairs.first?.left.id == "vscode.fold")

        // App without pairs
        let zoomPairs = catalog.pairs(for: "us.zoom.xos")
        #expect(zoomPairs.isEmpty)
    }

    @Test func searchMatchesKeywordsAppCategoryAndShortcuts() {
        let catalog = ActionPackCatalog.shared

        let zoom = catalog.pack(for: "us.zoom.xos")!
        // Keywords are whole words: "webcam" is one, "webc" is part of one
        let video = zoom.actions.first { $0.id == "zoom.video" }!
        #expect(!ActionPackCatalog.matches(action: video, query: "webc", appName: "Zoom"))
        #expect(ActionPackCatalog.matches(action: video, query: "webcam", appName: "Zoom"))

        // Keyword search: "mic" should match Zoom audio mute
        let zoomMute = zoom.actions.first { $0.id == "zoom.muteAudio" }!
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "mic", appName: "Zoom"))
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "microphone", appName: "Zoom"))

        // Shortcut words search: "command shift a"
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "command shift a", appName: "Zoom"))
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "shift+cmd+a", appName: "Zoom"))

        // App name search
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "zoom", appName: "Zoom"))

        // Category search
        #expect(ActionPackCatalog.matches(action: zoomMute, query: "meeting", appName: "Zoom"))

        // appsMatchingSearch for Mouse scope hint
        let appsWithBrush = catalog.appsMatchingSearch("brush")
        #expect(appsWithBrush.contains("Adobe Photoshop"))
    }
}
