import Foundation

// Per-app settings: `"apps": {"<bundle id>": {"buttons": …, "thumbWheel": …, "smoothScroll": …}}`.
// Each app's sections are decoded on top of the global ones, so an app names only what differs:
// the buttons it lists (and, for a gesture, the directions it lists), the thumb wheel keys it sets,
// the smooth scrolling keys it sets. Everything else (DPI, wheel mode, inversion, gesture
// distance) writes to the mouse or is read once, so it stays global.

extension Config {
    /// What applies in one app (or everywhere): bindings, thumb wheel and smooth scrolling.
    public struct AppSettings: Sendable {
        public var bindings: [UInt16: Binding]
        public var thumbWheel: ThumbWheel
        public var smoothScroll: SmoothScroll?
        /// The controls the app's `buttons` names; every other binding is the global one.
        public var buttons: Set<UInt16> = []
        /// Which sections the app sets, so the daemon looks the app up only where it matters.
        public var setsButtons = false
        public var setsThumbWheel = false
        public var setsSmoothScroll = false
    }

    /// The settings that apply everywhere no app entry matches.
    public var global: AppSettings {
        AppSettings(bindings: bindings, thumbWheel: thumbWheel ?? ThumbWheel(), smoothScroll: smoothScroll)
    }

    /// The settings for the app with this bundle ID, or nil when no entry names it. Bundle IDs
    /// match without regard to case, as LaunchServices matches them.
    public func settings(forApp bundleID: String) -> AppSettings? {
        apps.isEmpty ? nil : apps[bundleID.lowercased()]
    }

    /// Every control bound globally or in any app: the controls the daemon diverts.
    public var boundControls: Set<UInt16> {
        apps.values.reduce(into: Set(bindings.keys)) { $0.formUnion($1.bindings.keys) }
    }

    /// The sections an app may set; anything else in an app entry is ignored with a warning.
    static let appSections: Set = ["buttons", "thumbWheel", "smoothScroll"]

    mutating func decodeApps(_ c: KeyedDecodingContainer<AnyKey>) throws {
        let base = global
        for key in c.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            let id = key.stringValue
            let entry = try c.nestedContainer(keyedBy: AnyKey.self, forKey: key)
            var app = base
            for section in entry.allKeys.map(\.stringValue).sorted() where !Self.appSections.contains(section) {
                warnings.append("apps.\(id).\(section) is not a per-app setting; ignored")
            }
            if entry.contains(AnyKey("buttons")) {
                app.setsButtons = true
                let buttons = try entry.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("buttons"))
                for name in buttons.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                    guard let cid = Button.cid(for: name.stringValue) else {
                        warnings.append("apps.\(id).buttons: unknown button '\(name.stringValue)'")
                        continue
                    }
                    app.bindings[cid] = try Binding.decode(buttons, forKey: name, base: base.bindings[cid])
                    app.buttons.insert(cid)
                }
            }
            if entry.contains(AnyKey("thumbWheel")) {
                app.setsThumbWheel = true
                let thumb = try entry.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("thumbWheel"))
                if thumb.contains(AnyKey("inverted")) {
                    warnings.append("apps.\(id).thumbWheel.inverted is global only; ignored")
                }
                app.thumbWheel = try ThumbWheel(thumb, base: base.thumbWheel)
            }
            if entry.contains(AnyKey("smoothScroll")) {
                app.setsSmoothScroll = true
                let smooth = try entry.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("smoothScroll"))
                app.smoothScroll = try SmoothScroll(smooth, base: base.smoothScroll ?? SmoothScroll())
            }
            let folded = id.lowercased()
            if apps[folded] != nil { warnings.append("apps.\(id) repeats another entry; the last one applies") }
            apps[folded] = app
        }
    }
}
