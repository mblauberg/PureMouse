import Foundation
import HIDPP

/// User configuration, read from `~/.config/puremouse/config.json`. Every field is optional;
/// omitted settings are left as the device has them.
struct Config: Decodable {
    /// Sensor resolution, snapped to the nearest value the sensor reports it supports (the
    /// MX Master 3S accepts 200–8000 in steps of 50).
    var dpi: Int?
    var scrollWheel: ScrollWheel?
    var thumbWheel: ThumbWheel?
    /// When present, PureMouse takes both wheels over and scrolls smoothly itself (instead of Mos).
    var smoothScroll: SmoothScroll?
    /// Button name (see `Button`) or hex control ID (e.g. "0x00c4") → binding.
    var buttons: [String: Binding] = [:]
    var gesture = GestureSettings()
    /// `buttons` keyed by control ID. Unknown names are reported once, at load, and skipped.
    private(set) var bindings: [UInt16: Binding] = [:]

    private enum CodingKeys: String, CodingKey { case dpi, scrollWheel, thumbWheel, smoothScroll, buttons, gesture }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        scrollWheel = try c.decodeIfPresent(ScrollWheel.self, forKey: .scrollWheel)
        thumbWheel = try c.decodeIfPresent(ThumbWheel.self, forKey: .thumbWheel)
        smoothScroll = try c.decodeIfPresent(SmoothScroll.self, forKey: .smoothScroll)
        buttons = try c.decodeIfPresent([String: Binding].self, forKey: .buttons) ?? [:]
        gesture = try c.decodeIfPresent(GestureSettings.self, forKey: .gesture) ?? GestureSettings()
        for (name, binding) in buttons {
            guard let cid = Button.cid(for: name) else {
                Log.error("config: unknown button '\(name)'")
                continue
            }
            bindings[cid] = binding
        }
    }

    struct ScrollWheel: Decodable {
        /// Inverts the wheel relative to the system scroll direction. With macOS natural
        /// scrolling on, true gives classic mouse-wheel direction without touching the trackpad.
        var inverted: Bool?
        /// Wheel mode on first connect. Later toggles are kept across reconnects.
        var mode: WheelMode?
        /// SmartShift: 1–50 switches to free-spin automatically above that wheel speed; 255 disables it.
        var smartShiftThreshold: UInt8?
    }

    enum WheelMode: String, Decodable {
        case ratchet, freespin
        var smartShift: SmartShift.Mode { self == .ratchet ? .ratchet : .freespin }
    }

    struct ThumbWheel: Decodable {
        var inverted: Bool?
    }

    struct SmoothScroll: Decodable {
        /// Distance multiplier for the main wheel; 1 is about 40 pixels per notch when slow.
        var speed = 1.0
        /// Distance multiplier for the thumb wheel; 1 is about 360 pixels per rotation when slow.
        var horizontalSpeed = 1.0
        /// How much faster spinning travels further per notch; 0 is linear.
        var acceleration = 1.0
        /// Time for a scroll to glide to rest; 0 posts each movement immediately.
        var smoothingMs = 125.0
        /// Shift + wheel scrolls horizontally.
        var shiftScrollsHorizontally = true

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            func value<T: Decodable>(_ key: String, _ fallback: T) throws -> T {
                try c.decodeIfPresent(T.self, forKey: AnyKey(key)) ?? fallback
            }
            speed = try value("speed", speed)
            horizontalSpeed = try value("horizontalSpeed", horizontalSpeed)
            acceleration = try value("acceleration", acceleration)
            smoothingMs = try value("smoothingMs", smoothingMs)
            shiftScrollsHorizontally = try value("shiftScrollsHorizontally", shiftScrollsHorizontally)
        }
    }

    struct GestureSettings: Decodable {
        /// Travel before a direction fires, in millimetres (converted using the DPI).
        var distanceMm = 4.0
        /// Minimum time between repeated directions within one hold (e.g. several Space switches).
        var repeatIntervalMs = 400

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            distanceMm = try c.decodeIfPresent(Double.self, forKey: AnyKey("distanceMm")) ?? distanceMm
            repeatIntervalMs = try c.decodeIfPresent(Int.self, forKey: AnyKey("repeatIntervalMs")) ?? repeatIntervalMs
        }
    }

    enum Binding: Decodable {
        case action(Action)
        case gesture(Gesture)

        struct Gesture: Decodable {
            var click: Action = .none
            var up: Action = .none
            var down: Action = .none
            var left: Action = .none
            var right: Action = .none

            init(from decoder: Decoder) throws {
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

            func action(for direction: GestureRecognizer.Direction) -> Action {
                switch direction {
                case .up: up
                case .down: down
                case .left: left
                case .right: right
                }
            }
        }

        init(from decoder: Decoder) throws {
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
    enum Button: String {
        case middle, back, forward, gesture, top

        var cid: UInt16 {
            switch self {
            case .middle: 0x0052
            case .back: 0x0053
            case .forward: 0x0056
            case .gesture: 0x00C3  // thumb button
            case .top: 0x00C4      // mode-shift button behind the wheel
            }
        }

        static func cid(for name: String) -> UInt16? {
            if let button = Button(rawValue: name) { return button.cid }
            let hex = name.lowercased().hasPrefix("0x") ? String(name.dropFirst(2)) : name
            return UInt16(hex, radix: 16)
        }
    }

    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/puremouse/config.json")

    static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// No settings: devices are left exactly as they are.
    static let empty = try! JSONDecoder().decode(Config.self, from: Data("{}".utf8))
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
