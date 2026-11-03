import Foundation

/// Something a button or gesture direction does. In config JSON an action is either a name
/// (`"missionControl"`) or an object with keys, run or haptic.
/// Data only: the daemon performs actions (`SystemActions`).
public enum Action: Equatable, Decodable, Sendable {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case navigateBack
    case navigateForward
    /// Flip the scroll wheel between ratchet and free-spin. Handled by the device session.
    case toggleScrollMode
    /// Step to the next of `Config.dpiPresets`. Handled by the device session.
    case cycleDPI
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case nextTrack
    case previousTrack
    case middleClick
    case brightnessUp
    case brightnessDown
    /// Ctrl+Tab and Ctrl+Shift+Tab, which most tabbed apps take as next and previous tab.
    case nextTab
    case previousTab
    /// Cmd+= and Cmd+-, the zoom shortcuts most apps share.
    case zoomIn
    case zoomOut
    /// Play an effect on a supporting mouse, without changing its haptic configuration.
    case haptic(HapticWaveform)
    case keys(Keystroke)
    case run(String)
    /// Slows the pointer while its button is held: the live DPI drops to `dpi` (snapped to the
    /// mouse's steps), or to half the speed in effect when nil, and returns when the button is let
    /// go. Handled by the device session; only a click or a hold can be one (`isWhileHeld`).
    case precisePointer(dpi: Int?)
    /// Presses the left button and keeps it down until the next Drag Lock, so the pointer drags.
    case dragLock

    /// Every action that has a name, by its config name.
    public static let named: [String: Action] = [
        "none": .none, "missionControl": .missionControl, "appExpose": .appExpose,
        "showDesktop": .showDesktop, "launchpad": .launchpad, "spaceLeft": .spaceLeft,
        "spaceRight": .spaceRight, "navigateBack": .navigateBack, "navigateForward": .navigateForward,
        "toggleScrollMode": .toggleScrollMode, "cycleDPI": .cycleDPI,
        "volumeUp": .volumeUp, "volumeDown": .volumeDown, "mute": .mute,
        "playPause": .playPause, "nextTrack": .nextTrack, "previousTrack": .previousTrack,
        "middleClick": .middleClick,
        "brightnessUp": .brightnessUp, "brightnessDown": .brightnessDown,
        "nextTab": .nextTab, "previousTab": .previousTab, "zoomIn": .zoomIn, "zoomOut": .zoomOut,
        "precisePointer": .precisePointer(dpi: nil), "dragLock": .dragLock,
    ]

    /// Lasts while its button is held rather than happening once, so it can be a click (which then
    /// owns the button: the binding's other triggers do nothing) or a hold, and nothing else.
    public var isWhileHeld: Bool {
        if case .precisePointer = self { true } else { false }
    }

    /// The config name, for messages: `named`'s key, or the object form's.
    public var name: String {
        switch self {
        case .precisePointer: "precisePointer"
        case .keys: "keys"
        case .run: "run"
        case .haptic: "haptic"
        default: Self.named.first { $0.value == self }?.key ?? "\(self)"
        }
    }

    /// Handled by the device session rather than `SystemActions`.
    public var actsOnDevice: Bool {
        switch self {
        case .toggleScrollMode, .cycleDPI, .haptic, .precisePointer: true
        default: false
        }
    }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let action = Self.named[name] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "unknown action “\(name)”"))
            }
            self = action
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let spec = try c.decodeIfPresent(String.self, forKey: AnyKey("keys")) {
            guard let keystroke = Keystroke(spec) else {
                throw DecodingError.dataCorruptedError(forKey: AnyKey("keys"), in: c,
                                                       debugDescription: "can't parse keystroke '\(spec)'")
            }
            self = .keys(keystroke)
        } else if let command = try c.decodeIfPresent(String.self, forKey: AnyKey("run")) {
            self = .run(command)
        } else if let waveform = try c.decodeIfPresent(HapticWaveform.self, forKey: AnyKey("haptic")) {
            self = .haptic(waveform)
        } else if let dpi = try c.decodeIfPresent(Int.self, forKey: AnyKey("precisePointer"), in: Config.dpiRange) {
            self = .precisePointer(dpi: dpi)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "expected an action name, {\"keys\": ...}, {\"run\": ...}, {\"haptic\": ...} or {\"precisePointer\": ...}"))
        }
    }
}

/// Solaar's HapticWaveForms table plus Logi Options+ breathing/timer effects.
/// Names are config values; IDs are device protocol data.
public enum HapticWaveform: String, CaseIterable, Decodable, Sendable {
    case sharpStateChange, dampStateChange, sharpCollision, dampCollision, subtleCollision
    case happyAlert, angryAlert, completed, square, wave, firework, mad, knock, jingle, ringing
    case simpleBreathing, boxBreathing, bellyBreathing, timer, startEndBreathingSignal
    case whisperCollision

    public var id: UInt8 {
        switch self {
        case .sharpStateChange: 0x00
        case .dampStateChange: 0x01
        case .sharpCollision: 0x02
        case .dampCollision: 0x03
        case .subtleCollision: 0x04
        case .happyAlert: 0x05
        case .angryAlert: 0x06
        case .completed: 0x07
        case .square: 0x08
        case .wave: 0x09
        case .firework: 0x0A
        case .mad: 0x0B
        case .knock: 0x0C
        case .jingle: 0x0D
        case .ringing: 0x0E
        case .simpleBreathing: 0x0F
        case .boxBreathing: 0x10
        case .bellyBreathing: 0x11
        case .timer: 0x12
        case .startEndBreathingSignal: 0x13
        case .whisperCollision: 0x1B
        }
    }
}
