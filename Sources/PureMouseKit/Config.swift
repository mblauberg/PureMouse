import Foundation

/// User configuration, read from `~/.config/puremouse/config.json`. Every field is optional;
/// omitted settings are left as the device has them. Numbers outside their ranges fail the load
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
    public var gesture = GestureSettings()
    /// `buttons` keyed by control ID.
    public private(set) var bindings: [UInt16: Binding] = [:]
    /// Names in `buttons` that are neither a `Button` nor a hex control ID; skipped. The daemon
    /// logs them once, at load.
    public private(set) var unknownButtons: [String] = []

    private enum CodingKeys: String, CodingKey {
        case dpi, dpiPresets, scrollWheel, thumbWheel, smoothScroll, buttons, gesture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi, in: Self.dpiRange)
        if c.contains(.dpiPresets) {
            var list = try c.nestedUnkeyedContainer(forKey: .dpiPresets)
            while !list.isAtEnd {
                guard dpiPresets.count < Self.dpiPresetsCount.upperBound else {
                    throw DecodingError.dataCorruptedError(forKey: .dpiPresets, in: c,
                        debugDescription: "dpiPresets has more than \(Self.dpiPresetsCount.upperBound) entries")
                }
                let value = try list.decode(Int.self)
                guard Self.dpiRange.contains(value) else {
                    throw DecodingError.dataCorruptedError(forKey: .dpiPresets, in: c,
                        debugDescription: "dpiPresets[\(dpiPresets.count)] must be \(Self.dpiRange.lowerBound)–\(Self.dpiRange.upperBound), not \(value)")
                }
                dpiPresets.append(value)
            }
        }
        scrollWheel = try c.decodeIfPresent(ScrollWheel.self, forKey: .scrollWheel)
        thumbWheel = try c.decodeIfPresent(ThumbWheel.self, forKey: .thumbWheel)
        smoothScroll = try c.decodeIfPresent(SmoothScroll.self, forKey: .smoothScroll)
        buttons = try c.decodeIfPresent([String: Binding].self, forKey: .buttons) ?? [:]
        gesture = try c.decodeIfPresent(GestureSettings.self, forKey: .gesture) ?? GestureSettings()
        for (name, binding) in buttons {
            guard let cid = Button.cid(for: name) else {
                unknownButtons.append(name)
                continue
            }
            bindings[cid] = binding
        }
        unknownButtons.sort()
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
            let c = try decoder.container(keyedBy: AnyKey.self)
            inverted = try c.decodeIfPresent(Bool.self, forKey: AnyKey("inverted"))
            mode = try c.decodeIfPresent(WheelMode.self, forKey: AnyKey("mode"))
            smartShiftThreshold = try c.decodeIfPresent(UInt8.self, forKey: AnyKey("smartShiftThreshold"), in: 1...255)
        }
    }

    public enum WheelMode: String, Decodable, Sendable {
        case ratchet, freespin
    }

    public struct ThumbWheel: Decodable, Sendable {
        public var inverted: Bool?
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
            let c = try decoder.container(keyedBy: AnyKey.self)
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
            let c = try decoder.container(keyedBy: AnyKey.self)
            distanceMm = try c.decodeIfPresent(Double.self, forKey: AnyKey("distanceMm"), in: Self.distanceMmRange)
                ?? distanceMm
            repeatIntervalMs = try c.decodeIfPresent(Int.self, forKey: AnyKey("repeatIntervalMs"),
                                                     in: Self.repeatIntervalMsRange) ?? repeatIntervalMs
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
                let c = try decoder.container(keyedBy: AnyKey.self)
                func action(_ key: String) throws -> Action {
                    try c.decodeIfPresent(Action.self, forKey: AnyKey(key)) ?? .none
                }
                click = try action("click")
                up = try action("up")
                down = try action("down")
                left = try action("left")
                right = try action("right")
            }
        }

        public init(from decoder: Decoder) throws {
            if Self.looksLikeGesture(decoder) {
                self = .gesture(try Gesture(from: decoder))
            } else {
                self = .action(try Action(from: decoder))
            }
        }

        private static func looksLikeGesture(_ decoder: Decoder) -> Bool {
            guard let keys = try? decoder.container(keyedBy: AnyKey.self).allKeys else { return false }
            let gestureKeys: Set = ["click", "up", "down", "left", "right"]
            return !keys.isEmpty && keys.allSatisfy { gestureKeys.contains($0.stringValue) }
        }
    }

    /// Friendly names for MX Master control IDs. Hex IDs work for anything else.
    public enum Button: String, CaseIterable, Sendable {
        case middle, back, forward, gesture, top

        public var cid: UInt16 {
            switch self {
            case .middle: 0x0052
            case .back: 0x0053
            case .forward: 0x0056
            case .gesture: 0x00C3  // thumb button
            case .top: 0x00C4      // mode-shift button behind the wheel
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

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/puremouse/config.json")
    }

    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// No settings: devices are left exactly as they are.
    public static let empty = try! JSONDecoder().decode(Config.self, from: Data("{}".utf8))
}

extension KeyedDecodingContainer {
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
