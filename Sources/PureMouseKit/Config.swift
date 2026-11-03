import Foundation

/// User configuration, read from `~/.config/puremouse/config.json`. Every field is optional: a
/// setting the file leaves out takes its value from the default set (`defaultSetJSON`), and the
/// few the default set leaves unset (DPI, wheel direction, wheel mode and SmartShift) are left as
/// the device has them. No file is the same as `{}`: the default set. Numbers outside their
/// ranges fail the load
/// (a reload then keeps the previous config) rather than overflowing later, mid-session.
///
/// Shared by the daemon and the menu bar app, which validates with this decoder before writing
/// (`ConfigCheck`). Data only: applying it to a mouse lives in the daemon.
public struct Config: Decodable, Sendable {
    /// Sensor resolution, snapped to the nearest value the sensor reports it supports (the
    /// MX Master 3S accepts 200–8000 in steps of 50).
    public var dpi: Int?
    public static let dpiRange = 50...25600
    /// Resolutions the `cycleDPI` action steps through, each within `dpiRange`; the menu bar app
    /// offers them too.
    public var dpiPresets: [Int] = []
    public static let dpiPresetsCount = 0...8
    public var scrollWheel: ScrollWheel?
    public var thumbWheel: ThumbWheel?
    /// When present and enabled, PureMouse takes both wheels over and scrolls smoothly itself.
    public var smoothScroll: SmoothScroll?
    /// Button name (see `Button`) or hex control ID (e.g. "0x00c4") → binding.
    public var buttons: [String: Binding] = [:]
    /// Primary clicks must always remain native, including controls reported as divertable.
    public static let reservedControls: Set<UInt16> = [0x0050, 0x0051]
    public var gesture = GestureSettings()
    public var universalControl = UniversalControl()
    /// `buttons` keyed by control ID.
    public private(set) var bindings: [UInt16: Binding] = [:]
    /// Names in `buttons` that are neither a `Button` nor a hex control ID; skipped. The daemon
    /// logs them once, at load.
    public internal(set) var unknownButtons: [String] = []
    /// Per-app settings by lowercased bundle ID, each already merged onto the global ones
    /// (`Config+Apps.swift`).
    public internal(set) var apps: [String: AppSettings] = [:]
    /// Per-device settings by device key (`Config+Devices.swift`), each resolved: the top level,
    /// the entry on top, then `apps` merged onto that.
    public internal(set) var devices: [String: Config] = [:]
    /// Problems that do not fail the load, such as a per-app key that is global only, worded
    /// for the log. The daemon logs them once, at load.
    public internal(set) var warnings: [String] = []

    init() {}

    public init(from decoder: Decoder) throws {
        try self.init(decoder.container(keyedBy: AnyKey.self))
    }

    /// The default set, then the file on top of it (`decodeFile`).
    init(_ c: KeyedDecodingContainer<AnyKey>) throws {
        self = Self.defaults
        try decodeFile(c)
    }

    /// The top level, then `apps` decoded against it, then each `devices` entry. `decodeSections`
    /// is the one layering point: a device entry decodes its sections on top of the top level's
    /// (`Config+Devices.swift`).
    mutating func decodeFile(_ c: KeyedDecodingContainer<AnyKey>) throws {
        try decodeSections(c)
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("universalControl")) {
            universalControl = try UniversalControl(section, base: universalControl)
        }
        let appsSection = c.contains(AnyKey("apps"))
            ? try c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("apps")) : nil
        if let appsSection { try decodeApps(appsSection) }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("devices")) {
            try decodeDevices(section, apps: appsSection)
        }
    }

    /// The sections a device entry may set too (`deviceSections`), each on top of the same
    /// section of `self`: a section `c` leaves out stays as it is, `dpiPresets` replaces the whole
    /// list and a binding replaces the one for its control.
    mutating func decodeSections(_ c: KeyedDecodingContainer<AnyKey>) throws {
        dpi = try c.decodeIfPresent(Int.self, forKey: AnyKey("dpi"), in: Self.dpiRange) ?? dpi
        if c.contains(AnyKey("dpiPresets")) {
            let key = AnyKey("dpiPresets")
            var presets: [Int] = []
            var list = try c.nestedUnkeyedContainer(forKey: key)
            while !list.isAtEnd {
                guard presets.count < Self.dpiPresetsCount.upperBound else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                        debugDescription: "dpiPresets has more than \(Self.dpiPresetsCount.upperBound) entries")
                }
                let value = try list.decode(Int.self)
                guard Self.dpiRange.contains(value) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                        debugDescription: "dpiPresets[\(presets.count)] must be \(Self.dpiRange.lowerBound)–\(Self.dpiRange.upperBound), not \(value)")
                }
                presets.append(value)
            }
            dpiPresets = presets
        }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("scrollWheel")) {
            scrollWheel = try ScrollWheel(section, base: scrollWheel)
        }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("thumbWheel")) {
            thumbWheel = try ThumbWheel(global: section, base: thumbWheel ?? ThumbWheel())
        }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("smoothScroll")) {
            smoothScroll = try SmoothScroll(section, base: smoothScroll ?? SmoothScroll())
        }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("buttons")) {
            try decodeButtons(section)
        }
        if let section = try c.nestedContainerIfPresent(forKey: AnyKey("gesture")) {
            gesture = try GestureSettings(section, base: gesture)
        }
    }

    /// For a binding of a primary click (`reservedControls`), keyed as the user spelled it.
    static func reservedWarning(_ path: String) -> String {
        "\(path): the left and right buttons always click; ignored"
    }

    /// Adds the bindings `c` names to `buttons` and `bindings`. A name for a control that `buttons`
    /// held before replaces the earlier name and binding, and a gesture keeps the directions it
    /// leaves out. `"default"` (`Binding.nativeValue`) binds nothing: it removes the binding and
    /// every name `buttons` held for that control, which is how the top level, a device entry or an
    /// app leaves a button that a wider scope, or the default set, binds to the mouse's own behaviour. Names within `c` do not layer on each
    /// other; if two name one control, the last in sorted order decides it. When that is a binding,
    /// the names of the bindings before it stay in `buttons` too; when it is `"default"`, none of
    /// them does, and the control has no binding.
    private mutating func decodeButtons(_ c: KeyedDecodingContainer<AnyKey>) throws {
        let before = bindings
        let earlier = Set(buttons.keys)
        var named: [String: Binding] = [:]
        var bound: [UInt16: Binding] = [:]
        var cleared: Set<UInt16> = []
        var unknown: Set<String> = Set(unknownButtons)
        for name in c.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            let cid = Button.cid(for: name.stringValue)
            let isNative = Binding.isNative(c, forKey: name)
            let binding = isNative ? nil : try Binding.decode(c, forKey: name, base: cid.flatMap { before[$0] })
            if let cid, Self.reservedControls.contains(cid) {
                warnings.append(Self.reservedWarning("buttons.\(name.stringValue)"))
                continue
            }
            guard let cid else {
                if let binding { named[name.stringValue] = binding }
                unknown.insert(name.stringValue)
                continue
            }
            if let binding {
                named[name.stringValue] = binding
                bound[cid] = binding
                cleared.remove(cid)
            } else {
                for other in named.keys where Button.cid(for: other) == cid { named[other] = nil }
                bound[cid] = nil
                cleared.insert(cid)
            }
        }
        for name in earlier where Button.cid(for: name).map({ bound[$0] != nil || cleared.contains($0) }) == true {
            buttons[name] = nil
        }
        buttons.merge(named) { _, new in new }
        bindings.merge(bound) { _, new in new }
        for cid in cleared { bindings[cid] = nil }
        unknownButtons = unknown.sorted()
    }

    public struct ScrollWheel: Decodable, Sendable {
        /// Inverts the wheel relative to the system scroll direction. With macOS natural
        /// scrolling on, true gives classic mouse-wheel direction without touching the trackpad.
        public var inverted: Bool?
        /// Wheel mode on first connect. Later toggles are kept across reconnects.
        public var mode: WheelMode?
        /// SmartShift: 1–50 switches to free-spin automatically above that wheel speed; 255 disables it.
        /// 0 is rejected: on the wire it means "unchanged".
        public var smartShiftThreshold: UInt8?

        public init(from decoder: Decoder) throws {
            try self.init(decoder.container(keyedBy: AnyKey.self), base: nil)
        }

        /// The keys `c` names, the rest from `base` (or unset).
        init(_ c: KeyedDecodingContainer<AnyKey>, base: ScrollWheel?) throws {
            if let base { self = base }
            inverted = try c.decodeIfPresent(Bool.self, forKey: AnyKey("inverted")) ?? inverted
            mode = try c.decodeIfPresent(WheelMode.self, forKey: AnyKey("mode")) ?? mode
            smartShiftThreshold = try c.decodeIfPresent(UInt8.self, forKey: AnyKey("smartShiftThreshold"), in: 1...255)
                ?? smartShiftThreshold
        }
    }

    public enum WheelMode: String, Decodable, Sendable {
        case ratchet, freespin
    }

    public struct ThumbWheel: Decodable, Sendable {
        /// Inverts the thumb wheel's scrolling: in hardware when it reports natively, in software
        /// when PureMouse handles it. Global only; actions follow `reversed` instead.
        public var inverted: Bool?
        /// Swaps which action each direction performs (actions mode only). Per app too.
        public var reversed = false
        /// What turning the wheel does.
        public var mode: Mode = .scroll
        /// The wheel's own steps per action (18 per turn on the MX Master 3S).
        public var step = Self.defaultStep

        public enum Mode: Equatable, Sendable {
            /// Horizontal scrolling, as without PureMouse.
            case scroll
            /// One action per `step`: `left` for turns that scroll left with natural scrolling
            /// off, `right` for the other way (swapped by `reversed`; `inverted` and natural
            /// scrolling do not affect them).
            case actions(left: Action, right: Action)
        }

        public static let stepRange = 1...36
        public static let defaultStep = 3
        /// The `action` names besides "scroll": an action pair and its default step.
        public static let presets: [String: (left: Action, right: Action, step: Int)] = [
            "zoom": (.zoomOut, .zoomIn, 3),
            "volume": (.volumeDown, .volumeUp, 2),
            "tabs": (.previousTab, .nextTab, 3),
            "spaces": (.spaceLeft, .spaceRight, 4),
        ]

        public init() {}

        public init(from decoder: Decoder) throws {
            try self.init(global: decoder.container(keyedBy: AnyKey.self), base: ThumbWheel())
        }

        /// As `init(_:base:)`, and `inverted` too: the top-level section, where it applies.
        init(global c: KeyedDecodingContainer<AnyKey>, base: ThumbWheel) throws {
            try self.init(c, base: base)
            inverted = try c.decodeIfPresent(Bool.self, forKey: AnyKey("inverted")) ?? inverted
        }

        /// The keys `c` names, on top of `base`. `action` picks a pair and, if that changes the
        /// pair, its default step; `left` and `right` then replace one direction each, keeping the
        /// other and the step; `step` sets the step and `reversed` the direction.
        init(_ c: KeyedDecodingContainer<AnyKey>, base: ThumbWheel) throws {
            self = base
            if let name = try c.decodeIfPresent(String.self, forKey: AnyKey("action")) {
                if name == "scroll" {
                    mode = .scroll
                } else if let preset = Self.presets[name] {
                    let pair = Mode.actions(left: preset.left, right: preset.right)
                    if mode != pair { step = preset.step }
                    mode = pair
                } else {
                    throw DecodingError.dataCorruptedError(forKey: AnyKey("action"), in: c,
                        debugDescription: "unknown thumb wheel action '\(name)'; known: scroll, \(Self.presets.keys.sorted().joined(separator: ", ")), or left and right actions")
                }
            }
            let left = try c.decodeIfPresent(Action.self, forKey: AnyKey("left"))
            let right = try c.decodeIfPresent(Action.self, forKey: AnyKey("right"))
            if left != nil || right != nil {
                var pair: (left: Action, right: Action) = (.none, .none)
                if case .actions(let l, let r) = mode { pair = (l, r) }
                mode = .actions(left: left ?? pair.left, right: right ?? pair.right)
            }
            step = try c.decodeIfPresent(Int.self, forKey: AnyKey("step"), in: Self.stepRange) ?? step
            reversed = try c.decodeIfPresent(Bool.self, forKey: AnyKey("reversed")) ?? reversed
        }
    }

    public struct SmoothScroll: Decodable, Sendable {
        /// False scrolls natively (wheels not diverted) but keeps the tuning, so the menu bar app
        /// can switch smooth scrolling off and on without losing it.
        public var enabled = true
        /// Distance multiplier for the main wheel; 1 is about 40 pixels per notch when slow.
        public var speed = 1.0
        /// Distance multiplier for the thumb wheel; 1 is about 360 pixels per rotation when slow.
        public var horizontalSpeed = 1.0
        /// How much faster spinning travels further per notch; 0 is linear.
        public var acceleration = 1.0
        /// Time for a scroll to glide to rest; 0 posts each movement immediately.
        public var smoothingMs = 125.0
        /// Shift + wheel scrolls horizontally.
        public var shiftScrollsHorizontally = true

        public static let speedRange = 0.1...10.0
        public static let accelerationRange = 0.0...10.0
        public static let smoothingMsRange = 0.0...2000.0

        public init() {}

        public init(from decoder: Decoder) throws {
            try self.init(decoder.container(keyedBy: AnyKey.self), base: SmoothScroll())
        }

        /// The keys `c` names, on top of `base`.
        init(_ c: KeyedDecodingContainer<AnyKey>, base: SmoothScroll) throws {
            self = base
            func value(_ key: String, _ fallback: Double, in range: ClosedRange<Double>) throws -> Double {
                try c.decodeIfPresent(Double.self, forKey: AnyKey(key), in: range) ?? fallback
            }
            enabled = try c.decodeIfPresent(Bool.self, forKey: AnyKey("enabled")) ?? enabled
            speed = try value("speed", speed, in: Self.speedRange)
            horizontalSpeed = try value("horizontalSpeed", horizontalSpeed, in: Self.speedRange)
            acceleration = try value("acceleration", acceleration, in: Self.accelerationRange)
            smoothingMs = try value("smoothingMs", smoothingMs, in: Self.smoothingMsRange)
            shiftScrollsHorizontally = try c.decodeIfPresent(Bool.self, forKey: AnyKey("shiftScrollsHorizontally"))
                ?? shiftScrollsHorizontally
        }
    }

    public struct GestureSettings: Decodable, Sendable {
        /// Travel before a direction fires, in millimetres (converted using the DPI).
        public var distanceMm = 4.0
        /// Minimum time between repeated directions within one hold (e.g. several Space switches).
        public var repeatIntervalMs = 400

        public static let distanceMmRange = 0.5...50.0
        public static let repeatIntervalMsRange = 0...5000

        public init() {}

        public init(from decoder: Decoder) throws {
            try self.init(decoder.container(keyedBy: AnyKey.self), base: GestureSettings())
        }

        /// The keys `c` names, on top of `base`.
        init(_ c: KeyedDecodingContainer<AnyKey>, base: GestureSettings) throws {
            self = base
            distanceMm = try c.decodeIfPresent(Double.self, forKey: AnyKey("distanceMm"), in: Self.distanceMmRange)
                ?? distanceMm
            repeatIntervalMs = try c.decodeIfPresent(Int.self, forKey: AnyKey("repeatIntervalMs"),
                                                     in: Self.repeatIntervalMsRange) ?? repeatIntervalMs
        }
    }

    public struct UniversalControl: Decodable, Sendable {
        /// While the pointer is on another Mac, hand the wheels and buttons back to macOS so
        /// Universal Control forwards them; take them again when it returns.
        public var handOff = true

        public init() {}

        public init(from decoder: Decoder) throws {
            try self.init(decoder.container(keyedBy: AnyKey.self), base: UniversalControl())
        }

        /// The keys `c` names, on top of `base`.
        init(_ c: KeyedDecodingContainer<AnyKey>, base: UniversalControl) throws {
            self = base
            handOff = try c.decodeIfPresent(Bool.self, forKey: AnyKey("handOff")) ?? handOff
        }
    }

    public enum Binding: Decodable, Sendable {
        case action(Action)
        case gesture(Gesture)

        public struct Gesture: Decodable, Sendable {
            public var click: Action = .none
            public var up: Action = .none
            public var down: Action = .none
            public var left: Action = .none
            public var right: Action = .none

            public init(from decoder: Decoder) throws {
                try self.init(decoder.container(keyedBy: AnyKey.self), base: nil)
            }

            /// The directions `c` names, the rest from `base` (or none).
            init(_ c: KeyedDecodingContainer<AnyKey>, base: Gesture?) throws {
                if let base { self = base }
                func action(_ key: String, _ fallback: Action) throws -> Action {
                    try c.decodeIfPresent(Action.self, forKey: AnyKey(key)) ?? fallback
                }
                click = try action("click", click)
                up = try action("up", up)
                down = try action("down", down)
                left = try action("left", left)
                right = try action("right", right)
            }
        }

        public init(from decoder: Decoder) throws {
            if Self.looksLikeGesture(decoder) {
                self = .gesture(try Gesture(from: decoder))
            } else {
                self = .action(try Action(from: decoder))
            }
        }

        /// The reserved `buttons` value, the JSON string `"default"`, for no binding: the mouse's own
        /// behaviour. It is not an `Action`. It hides what the wider scope binds, and at the top level
        /// what the default set binds (back, forward and the gesture button).
        public static let nativeValue = "default"

        /// Whether the value at `key` is `nativeValue`.
        static func isNative(_ c: KeyedDecodingContainer<AnyKey>, forKey key: AnyKey) -> Bool {
            (try? c.decode(String.self, forKey: key)) == nativeValue
        }

        /// The binding at `key`; a gesture takes the directions it leaves out from `base`, when
        /// that is a gesture too.
        static func decode(_ c: KeyedDecodingContainer<AnyKey>, forKey key: AnyKey, base: Binding?) throws -> Binding {
            if let object = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key), isGesture(object.allKeys) {
                let baseGesture: Gesture? = if case .gesture(let g) = base { g } else { nil }
                return .gesture(try Gesture(object, base: baseGesture))
            }
            return .action(try c.decode(Action.self, forKey: key))
        }

        private static func looksLikeGesture(_ decoder: Decoder) -> Bool {
            guard let keys = try? decoder.container(keyedBy: AnyKey.self).allKeys else { return false }
            return isGesture(keys)
        }

        private static func isGesture(_ keys: [AnyKey]) -> Bool {
            let gestureKeys: Set = ["click", "up", "down", "left", "right"]
            return !keys.isEmpty && keys.allSatisfy { gestureKeys.contains($0.stringValue) }
        }
    }

    /// Friendly names for MX Master control IDs. Hex IDs work for anything else.
    public enum Button: String, CaseIterable, Sendable {
        case middle, back, forward, gesture, top, thumbPanel

        public var cid: UInt16 {
            switch self {
            case .middle: 0x0052
            case .back: 0x0053
            case .forward: 0x0056
            case .gesture: 0x00C3  // thumb button
            case .top: 0x00C4      // mode-shift button behind the wheel
            case .thumbPanel: 0x01A0 // MX Master 4 haptic / Actions Ring panel
            }
        }

        public init?(cid: UInt16) {
            guard let button = Self.allCases.first(where: { $0.cid == cid }) else { return nil }
            self = button
        }

        public static func cid(for name: String) -> UInt16? {
            if let button = Button(rawValue: name) { return button.cid }
            let hex = name.lowercased().hasPrefix("0x") ? String(name.dropFirst(2)) : name
            return UInt16(hex, radix: 16)
        }
    }

    /// What a control does without PureMouse, for the controls the daemon can reproduce: Mouse
    /// Default (`Binding.nativeValue`, or no binding where a press reaches the daemon anyway) does
    /// this, and Settings offers Mouse Default on a mouse or in an app only for these. Every other
    /// control has no behaviour of its own to give back.
    public enum NativeBehaviour: Equatable, Sendable {
        /// The ordinary mouse button, by its macOS number (middle 2, back 3, forward 4).
        case click(button: Int)
        /// What the mouse's own button does, as this action does it.
        case action(Action)
    }

    /// The native behaviour of the control `cid`, or nil when it has none the daemon can reproduce.
    public static func nativeBehaviour(of cid: UInt16) -> NativeBehaviour? {
        switch cid {
        case 0x0052: .click(button: 2)               // wheel press
        case 0x0053: .click(button: 3)               // back
        case 0x0056: .click(button: 4)               // forward
        case 0x00C4: .action(.toggleScrollMode)      // mode shift: the wheel's ratchet / free spin
        case 0x00FD: .action(.cycleDPI)              // DPI button
        default: nil
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/puremouse/config.json")
    }

    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// The default set, decoded once from `defaultSetJSON`.
    public static let defaults: Config = {
        do {
            return try JSONDecoder().decode(DefaultSet.self, from: Data(defaultSetJSON.utf8)).config
        } catch {
            preconditionFailure("The default set does not decode: \(error)")
        }
    }()

    /// The one definition of what a new install does. A missing file, `{}`, Reset All Settings and
    /// each pane's Restore Defaults all give it (docs/configuration.md, "Defaults"). It holds the
    /// settings a key left out would not give: smooth scrolling on at Balanced, and back, forward
    /// and the gesture button bound. The rest is what a key left out already means: the thumb wheel
    /// scrolls, not reversed (`ThumbWheel`), Universal Control hand-off is on (`UniversalControl`),
    /// Mouse Default on the wheel press and the top button, and DPI, wheel direction, wheel mode and
    /// SmartShift left as the mouse has them. Settings lays its tree over the same text
    /// (`ConfigTree.defaults`), so the two cannot differ.
    public static let defaultSetJSON = """
        {
          "smoothScroll": {"enabled": true, "speed": 1, "acceleration": 1, "smoothingMs": 125},
          "buttons": {
            "back": "navigateBack",
            "forward": "navigateForward",
            "gesture": {
              "click": "missionControl", "up": "missionControl", "down": "appExpose",
              "left": "spaceLeft", "right": "spaceRight"
            }
          }
        }
        """

    /// Decodes `defaultSetJSON` without layering it on itself.
    private struct DefaultSet: Decodable {
        let config: Config
        init(from decoder: Decoder) throws {
            var config = Config()
            try config.decodeFile(decoder.container(keyedBy: AnyKey.self))
            self.config = config
        }
    }
}

extension KeyedDecodingContainer {
    /// The object at `key`, or nil when the key is absent or null (as `decodeIfPresent` treats them).
    func nestedContainerIfPresent(forKey key: Key) throws -> KeyedDecodingContainer<AnyKey>? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try nestedContainer(keyedBy: AnyKey.self, forKey: key)
    }

    /// Decodes a number that must lie within `range`. Out-of-range values (and so NaN) are a
    /// decoding error naming the field, e.g. "smoothScroll.speed must be 0.1–10, not 1e+300".
    public func decodeIfPresent<T: Decodable & Comparable>(_ type: T.Type, forKey key: Key,
                                                           in range: ClosedRange<T>) throws -> T? {
        guard let value = try decodeIfPresent(type, forKey: key) else { return nil }
        guard range.contains(value) else {
            let field = (codingPath + [key]).map(\.stringValue).joined(separator: ".")
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\(field) must be \(range.lowerBound)–\(range.upperBound), not \(value)")
        }
        return value
    }
}

/// A coding key for any string, for containers whose keys are checked by hand.
public struct AnyKey: CodingKey, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ string: String) { stringValue = string }
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}
