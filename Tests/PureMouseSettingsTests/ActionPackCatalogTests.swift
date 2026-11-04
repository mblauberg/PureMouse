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

    /// A pack of six valid actions with one thing wrong, and the error validation names for it.
    enum Flaw: String, CaseIterable, CustomTestStringConvertible {
        case duplicateID, unknownBundleID, invalidPayload, fewerThanSixActions
        case missingSource, plainHTTPSource, brokenPairedOpposite

        var testDescription: String { rawValue }

        private static func entry(_ number: Int, id: String? = nil, bundleIDs: [String] = ["com.test"],
                                  payload: String? = nil, sourceURL: String = "https://example.com",
                                  pairedOpposite: String? = nil) -> ActionPackEntry {
            ActionPackEntry(id: id ?? "act\(number)", bundleIDs: bundleIDs, label: "Action \(number)", category: "Test",
                            payload: payload ?? "cmd+\(number)", sourceURL: sourceURL, verifiedDate: "2026-11-04",
                            pairedOpposite: pairedOpposite)
        }

        var data: ActionCatalogData {
            var actions = (1...5).map { Self.entry($0) }
            switch self {
            case .duplicateID:
                actions[1] = Self.entry(2, id: "act1")
                actions.append(Self.entry(6))
            case .unknownBundleID:
                actions[0] = Self.entry(1, bundleIDs: ["com.unknown"])
                actions.append(Self.entry(6))
            case .fewerThanSixActions: break
            case .invalidPayload: actions.append(Self.entry(6, payload: "invalid_key_combo@@@"))
            case .missingSource: actions.append(Self.entry(6, sourceURL: ""))
            case .plainHTTPSource: actions.append(Self.entry(6, sourceURL: "http://example.com"))
            case .brokenPairedOpposite: actions.append(Self.entry(6, pairedOpposite: "nonexistent_action_id"))
            }
            return ActionCatalogData(packs: [ActionPack(id: "test", name: "Test", bundleIDs: ["com.test"], actions: actions)])
        }

        var error: ActionPackCatalog.ValidationError {
            switch self {
            case .duplicateID: .duplicateActionID("act1")
            case .unknownBundleID: .unknownBundleID(actionID: "act1", bundleID: "com.unknown")
            case .invalidPayload: .invalidPayload(actionID: "act6", payload: "invalid_key_combo@@@")
            case .fewerThanSixActions: .insufficientActions(packID: "test", count: 5)
            case .missingSource: .missingVerification(actionID: "act6")
            case .plainHTTPSource: .invalidSourceURL(actionID: "act6", url: "http://example.com")
            case .brokenPairedOpposite: .invalidPairedOpposite(actionID: "act6", oppositeID: "nonexistent_action_id")
            }
        }
    }

    @Test func aPackOfSixValidActionsValidates() throws {
        let valid = ActionCatalogData(packs: [ActionPack(
            id: "test", name: "Test", bundleIDs: ["com.test"],
            actions: (1...6).map { ActionPackEntry(id: "act\($0)", bundleIDs: ["com.test"], label: "Action \($0)", category: "Test",
                                                   payload: "cmd+\($0)", sourceURL: "https://example.com", verifiedDate: "2026-11-04") })])
        try ActionPackCatalog.validate(valid)
    }

    @Test(arguments: Flaw.allCases)
    func validationRejectsEachFlawWithItsOwnError(flaw: Flaw) {
        #expect(throws: flaw.error) { try ActionPackCatalog.validate(flaw.data) }
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
