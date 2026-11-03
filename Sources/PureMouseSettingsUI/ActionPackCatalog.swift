import AppKit
import Foundation
import PureMouseAppSupport
import PureMouseKit

/// One action in a curated per-app action pack.
public struct ActionPackEntry: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let bundleIDs: [String]
    public let label: String
    public let category: String
    public let payload: String
    public let sourceURL: String
    public let verifiedDate: String
    public let keywords: [String]?
    public let keymapNote: String?
    public let pairedOpposite: String?
    public let pairLabel: String?

    public init(
        id: String,
        bundleIDs: [String],
        label: String,
        category: String,
        payload: String,
        sourceURL: String,
        verifiedDate: String,
        keywords: [String]? = nil,
        keymapNote: String? = nil,
        pairedOpposite: String? = nil,
        pairLabel: String? = nil
    ) {
        self.id = id
        self.bundleIDs = bundleIDs
        self.label = label
        self.category = category
        self.payload = payload
        self.sourceURL = sourceURL
        self.verifiedDate = verifiedDate
        self.keywords = keywords
        self.keymapNote = keymapNote
        self.pairedOpposite = pairedOpposite
        self.pairLabel = pairLabel
    }

    /// The ButtonAction this action binds to.
    public var buttonAction: ButtonAction {
        if ActionCatalog.symbol(for: payload) != nil {
            return .named(payload)
        }
        return .keys(payload)
    }

    /// Whether this action matches a given ButtonAction.
    public func matches(_ action: ButtonAction) -> Bool {
        switch action {
        case .keys(let spec):
            if let k1 = Keystroke(spec), let k2 = Keystroke(payload) {
                return k1 == k2
            }
            return spec.lowercased() == payload.lowercased()
        case .named(let name):
            return name == payload
        default:
            return false
        }
    }
}

/// A curated collection of actions for one app.
public struct ActionPack: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let bundleIDs: [String]
    public let actions: [ActionPackEntry]

    public init(id: String, name: String, bundleIDs: [String], actions: [ActionPackEntry]) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.actions = actions
    }
}

/// The top-level declarative catalogue data structure.
public struct ActionCatalogData: Sendable, Codable, Equatable {
    public let packs: [ActionPack]

    public init(packs: [ActionPack]) {
        self.packs = packs
    }
}

/// A pair of opposite pack actions for the thumb wheel.
public struct ActionPackPair: Identifiable, Sendable, Equatable {
    public var id: String { left.id + "+" + right.id }
    public let label: String
    public let left: ActionPackEntry
    public let right: ActionPackEntry

    public init(label: String, left: ActionPackEntry, right: ActionPackEntry) {
        self.label = label
        self.left = left
        self.right = right
    }
}

/// Bundled declarative catalogue of per-app actions, loaded on demand only by the Settings helper.
public final class ActionPackCatalog: @unchecked Sendable {
    public static let shared = ActionPackCatalog()

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case duplicateActionID(String)
        case unknownBundleID(actionID: String, bundleID: String)
        case invalidPayload(actionID: String, payload: String)
        case insufficientActions(packID: String, count: Int)
        case missingVerification(actionID: String)
        case invalidPairedOpposite(actionID: String, oppositeID: String)

        public var description: String {
            switch self {
            case .duplicateActionID(let id): "Duplicate action ID: \(id)"
            case .unknownBundleID(let actionID, let bundleID): "Action \(actionID) has unknown bundle ID: \(bundleID)"
            case .invalidPayload(let actionID, let payload): "Action \(actionID) has invalid shortcut payload: \(payload)"
            case .insufficientActions(let packID, let count): "Pack \(packID) has only \(count) actions (needs at least 6)"
            case .missingVerification(let actionID): "Action \(actionID) is missing source URL or verified date"
            case .invalidPairedOpposite(let actionID, let oppositeID): "Action \(actionID) references invalid opposite: \(oppositeID)"
            }
        }
    }

    public let data: ActionCatalogData
    private let packsByBundleID: [String: ActionPack]
    private let actionsByID: [String: ActionPackEntry]
    public let knownBundleIDs: Set<String>

    public init(data: ActionCatalogData) {
        self.data = data
        var byBundle: [String: ActionPack] = [:]
        var byID: [String: ActionPackEntry] = [:]
        var bundleIDs = Set<String>()

        for pack in data.packs {
            for b in pack.bundleIDs {
                let lower = b.lowercased()
                byBundle[lower] = pack
                bundleIDs.insert(lower)
            }
            for action in pack.actions {
                byID[action.id] = action
            }
        }

        self.packsByBundleID = byBundle
        self.actionsByID = byID
        self.knownBundleIDs = bundleIDs
    }

    public convenience init() {
        let loaded = Self.loadData()
        let decoded = (try? JSONDecoder().decode(ActionCatalogData.self, from: loaded)) ?? ActionCatalogData(packs: [])
        self.init(data: decoded)
    }

    public static func loadData() -> Data {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "ActionPacks", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        #endif
        return Data()
    }

    /// Validates acceptance criterion 1 across all packs in this catalog instance.
    public func validate() throws {
        try Self.validate(data)
    }

    /// Validates acceptance criterion 1 across all packs.
    public static func validate(_ data: ActionCatalogData) throws {
        var seenActionIDs = Set<String>()
        var knownBundles = Set<String>()
        for pack in data.packs {
            for b in pack.bundleIDs {
                knownBundles.insert(b.lowercased())
            }
        }

        for pack in data.packs {
            guard pack.actions.count >= 6 else {
                throw ValidationError.insufficientActions(packID: pack.id, count: pack.actions.count)
            }
            for action in pack.actions {
                guard seenActionIDs.insert(action.id).inserted else {
                    throw ValidationError.duplicateActionID(action.id)
                }
                guard !action.sourceURL.trimmingCharacters(in: .whitespaces).isEmpty,
                      !action.verifiedDate.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ValidationError.missingVerification(actionID: action.id)
                }
                for b in action.bundleIDs {
                    guard knownBundles.contains(b.lowercased()) else {
                        throw ValidationError.unknownBundleID(actionID: action.id, bundleID: b)
                    }
                }
                let isNamed = ActionCatalog.symbol(for: action.payload) != nil
                let isShortcut = ShortcutCheck.isValid(action.payload)
                guard isNamed || isShortcut else {
                    throw ValidationError.invalidPayload(actionID: action.id, payload: action.payload)
                }

                if let oppositeID = action.pairedOpposite {
                    guard let opposite = pack.actions.first(where: { $0.id == oppositeID }) else {
                        throw ValidationError.invalidPairedOpposite(actionID: action.id, oppositeID: oppositeID)
                    }
                    guard opposite.pairedOpposite == action.id else {
                        throw ValidationError.invalidPairedOpposite(actionID: action.id, oppositeID: oppositeID)
                    }
                }
            }
        }
    }

    public var packs: [ActionPack] { data.packs }

    public func pack(for bundleID: String) -> ActionPack? {
        packsByBundleID[bundleID.lowercased()]
    }

    public func action(matching binding: ButtonAction, in bundleID: String) -> ActionPackEntry? {
        guard let pack = pack(for: bundleID) else { return nil }
        return pack.actions.first { $0.matches(binding) }
    }

    public func pairs(for bundleID: String) -> [ActionPackPair] {
        guard let pack = pack(for: bundleID) else { return [] }
        var result: [ActionPackPair] = []
        var seenIDs = Set<String>()
        for action in pack.actions {
            guard let oppositeID = action.pairedOpposite,
                  !seenIDs.contains(action.id),
                  let opposite = pack.actions.first(where: { $0.id == oppositeID }) else {
                continue
            }
            seenIDs.insert(action.id)
            seenIDs.insert(opposite.id)
            let pairLabel = action.pairLabel ?? opposite.pairLabel ?? "\(action.label) / \(opposite.label)"
            result.append(ActionPackPair(label: pairLabel, left: action, right: opposite))
        }
        return result
    }

    /// Resolved thumb-wheel pairs with `ButtonAction`s for `ConfigTree` and `ThumbWheelRows`.
    public func resolvedThumbWheelPairs(for bundleID: String) -> [(id: String, label: String, left: ButtonAction, right: ButtonAction)] {
        pairs(for: bundleID).map { (id: $0.id, label: $0.label, left: $0.left.buttonAction, right: $0.right.buttonAction) }
    }

    public func pair(matchingLeft left: ButtonAction, right: ButtonAction, in bundleID: String) -> ActionPackPair? {
        for pair in pairs(for: bundleID) {
            if pair.left.matches(left) && pair.right.matches(right) {
                return pair
            }
        }
        return nil
    }

    /// Whether an action in a pack matches search query `query`.
    public static func matches(action: ActionPackEntry, query: String, appName: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if action.label.localizedStandardContains(q) { return true }
        if action.category.localizedStandardContains(q) { return true }
        if appName.localizedStandardContains(q) { return true }
        if let keywords = action.keywords, keywords.contains(where: { $0.localizedStandardContains(q) || q.localizedStandardContains($0) }) { return true }
        let words = Shortcut.spoken(action.payload) + " " + action.payload.replacingOccurrences(of: "+", with: " ")
        if words.localizedStandardContains(q) { return true }
        if let display = Shortcut.display(action.payload), display.localizedStandardContains(q) { return true }

        // Shortcut spec matching (e.g. "shift+cmd+a" matches "cmd+shift+a")
        if let (qMods, qKey) = Shortcut.parse(q), let (aMods, aKey) = Shortcut.parse(action.payload) {
            if qMods == aMods && qKey.caseInsensitiveCompare(aKey) == .orderedSame {
                return true
            }
        }

        // Shortcut words matching (e.g. "command shift a" matches cmd+shift+a regardless of word order)
        let qTokens = q.lowercased().split { $0.isWhitespace || $0 == "+" }.map(String.init)
        if !qTokens.isEmpty, let (aMods, aKey) = Shortcut.parse(action.payload) {
            var validTokens = Set<String>()
            validTokens.insert(aKey.lowercased())
            if aMods.contains(.command) { validTokens.insert("command"); validTokens.insert("cmd") }
            if aMods.contains(.shift) { validTokens.insert("shift") }
            if aMods.contains(.option) { validTokens.insert("option"); validTokens.insert("opt"); validTokens.insert("alt") }
            if aMods.contains(.control) { validTokens.insert("control"); validTokens.insert("ctrl") }
            if qTokens.allSatisfy({ validTokens.contains($0) }) {
                return true
            }
        }

        return false
    }

    /// Names of apps whose pack actions match `query` (for Mouse scope hint).
    public func appsMatchingSearch(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var matchedApps: [String] = []
        for pack in data.packs {
            let matched = pack.actions.contains { action in
                Self.matches(action: action, query: q, appName: pack.name)
            }
            if matched {
                matchedApps.append(pack.name)
            }
        }
        return matchedApps
    }
}
