import Foundation

/// The channel between the daemon and the menu bar app (see docs/companion.md). Two small JSON
/// files in `directory`, each written atomically by one side, plus a Darwin notification posted
/// after every write as a doorbell. Nothing polls, so both processes stay idle at zero CPU.
///
/// The notifications carry no data and anyone may post them; each side only reads its own user's
/// files, so a stray doorbell costs one file read.
public enum Companion {
    public static let daemonLabel = "io.github.mblauberg.puremouse"
    public static let menuLabel = "io.github.mblauberg.puremouse.menu"

    /// `~/Library/Application Support/PureMouse`, or `PUREMOUSE_COMPANION_DIR` when set (tests and
    /// development, so a fixture never collides with an installed daemon).
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["PUREMOUSE_COMPANION_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/PureMouse")
    }
    /// Written by the daemon: `Status`.
    public static var statusURL: URL { directory.appending(path: "status.json") }
    /// Written by the menu bar app: `Control`.
    public static var controlURL: URL { directory.appending(path: "control.json") }
    /// Created to ask the menu bar app to show Settings when it next starts, if within a few
    /// seconds (opening PureMouse.app restarts the menu agent just before opening it).
    public static var showSettingsURL: URL { directory.appending(path: "show-settings") }

    /// Posted by the daemon after writing `statusURL`.
    public static let statusNotification = doorbell("io.github.mblauberg.puremouse.status")
    /// Posted by the menu bar app after writing `controlURL`.
    public static let controlNotification = doorbell("io.github.mblauberg.puremouse.control")
    /// Posted by a second launch of the menu bar app (e.g. opened from the Finder) so the running
    /// one shows Settings before the second exits.
    public static let showSettingsNotification = doorbell("io.github.mblauberg.puremouse.menu.show")

    /// A doorbell's name: `base`, with a short hash of `PUREMOUSE_COMPANION_DIR` appended when that
    /// is set, so a development copy on a fixture directory never rings an installed app's bell.
    /// Unset leaves `base`, so builds with and without this still pair. The hash is FNV-1a, which
    /// (unlike `hashValue`) is the same in every process.
    public static func doorbell(_ base: String, directory: String? = ProcessInfo.processInfo.environment["PUREMOUSE_COMPANION_DIR"]) -> String {
        guard let directory else { return base }
        var hash: UInt32 = 2_166_136_261
        for byte in directory.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let digits = String(hash, radix: 16)
        return base + "." + String(repeating: "0", count: 8 - digits.count) + digits
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes `value` to `url` atomically, readable by this user only.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// What the daemon is doing, rewritten whenever any of it changes.
public struct Status: Codable, Equatable, Sendable {
    /// Bumped when the status or control shape changes; a reader seeing a newer version shows
    /// "update PureMouse".
    public static let currentSchema = 1

    public var schema = Status.currentSchema
    public var pid: Int32
    public var startedAt: Date
    /// The daemon's bundle version ("dev" for a `swift build` binary).
    public var version: String
    /// False only in the final status written while shutting down.
    public var running: Bool
    /// Paused through `Control.paused`: every mouse is back to native behaviour.
    public var paused: Bool
    public var permissions: Permissions
    /// A Logi Options+ process is running and will fight PureMouse over the mouse.
    public var logiOptionsRunning: Bool
    public var config: ConfigState
    public var devices: [Device]
    /// The current or most recent select-by-pressing request.
    public var capture: Capture?
    /// True while the pointer is on another Mac (Universal Control) and the mice are handed back
    /// to macOS for it.
    public var away: Bool

    public init(pid: Int32, startedAt: Date, version: String, running: Bool, paused: Bool,
                permissions: Permissions, logiOptionsRunning: Bool, config: ConfigState,
                devices: [Device], capture: Capture?, away: Bool = false) {
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.running = running
        self.paused = paused
        self.permissions = permissions
        self.logiOptionsRunning = logiOptionsRunning
        self.config = config
        self.devices = devices
        self.capture = capture
        self.away = away
    }

    public struct Permissions: Codable, Equatable, Sendable {
        public var accessibility: Bool
        public var inputMonitoring: Bool
        public init(accessibility: Bool, inputMonitoring: Bool) {
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
        }
    }

    public struct ConfigState: Codable, Equatable, Sendable {
        public var path: String
        /// Why the last load failed, while the daemon keeps running on the previous config.
        public var error: String?
        public init(path: String, error: String?) {
            self.path = path
            self.error = error
        }
    }

    public struct Device: Codable, Equatable, Sendable {
        /// Stable while the daemon runs: interface plus device index.
        public var id: String
        public var name: String
        public var connection: Connection
        /// Connected and answering; false while asleep or switched off.
        public var online: Bool
        public var battery: Battery?
        /// The DPI the sensor is set to now, if read.
        public var dpi: Int?
        /// Every DPI the sensor accepts, ascending; empty if it could not be read.
        public var dpiSteps: [Int]
        public var wheelMode: WheelMode?
        public var hasSmartShift: Bool
        public var hasThumbWheel: Bool
        /// Controls (buttons) the mouse can hand to PureMouse.
        public var controls: [Control]
        /// The key of this mouse in the config's `devices` section: `m` plus the 12 lowercase hex
        /// digits of its 0x0003 model ID when it reports one, else `p` plus its 4-digit lowercase
        /// hex product ID (e.g. `pb02c`). Nil when neither is known. Two mice of one model share it.
        public var model: String?
        /// The 0x0003 unit ID as 8 lowercase hex digits, when known: stable for one physical mouse,
        /// for state that belongs to a unit (low-battery alerts). Never written to the config.
        public var unit: String?
        /// A word such as "mouse", "trackball" or "keyboard".
        public var kind: String?
        /// What the mouse reports it can do; nil when not published. A member that is nil is
        /// unknown (not false).
        public var capabilities: Capabilities?

        public init(id: String, name: String, connection: Connection, online: Bool, battery: Battery?,
                    dpi: Int?, dpiSteps: [Int], wheelMode: WheelMode?, hasSmartShift: Bool,
                    hasThumbWheel: Bool, controls: [Control], model: String? = nil, unit: String? = nil,
                    kind: String? = nil, capabilities: Capabilities? = nil) {
            self.id = id
            self.name = name
            self.connection = connection
            self.online = online
            self.battery = battery
            self.dpi = dpi
            self.dpiSteps = dpiSteps
            self.wheelMode = wheelMode
            self.hasSmartShift = hasSmartShift
            self.hasThumbWheel = hasThumbWheel
            self.controls = controls
            self.model = model
            self.unit = unit
            self.kind = kind
            self.capabilities = capabilities
        }

        public enum Connection: String, Codable, Sendable { case receiver, bluetooth }
        public enum WheelMode: String, Codable, Sendable { case ratchet, freespin }

        public struct Battery: Codable, Equatable, Sendable {
            /// 0–100, when the mouse reports a percentage.
            public var percent: Int?
            public var level: Level
            public var charging: Bool
            public init(percent: Int?, level: Level, charging: Bool) {
                self.percent = percent
                self.level = level
                self.charging = charging
            }
            public enum Level: String, Codable, Sendable { case full, good, low, critical }
        }

        /// Each member is true (has it), false (reported not to) or nil (unknown or not asked yet:
        /// a lookup that failed transiently stays nil). Nil members are left out of the JSON.
        public struct Capabilities: Codable, Equatable, Sendable {
            public var dpi: Bool?
            public var smartShift: Bool?
            public var smoothScroll: Bool?
            public var thumbWheel: Bool?
            public var haptics: Bool?
            public var battery: Bool?
            /// HID++ feature IDs the mouse reports, as 4-digit lowercase hex strings, for support.
            public var features: [String]?

            public init(dpi: Bool? = nil, smartShift: Bool? = nil, smoothScroll: Bool? = nil,
                        thumbWheel: Bool? = nil, haptics: Bool? = nil, battery: Bool? = nil,
                        features: [String]? = nil) {
                self.dpi = dpi
                self.smartShift = smartShift
                self.smoothScroll = smoothScroll
                self.thumbWheel = thumbWheel
                self.haptics = haptics
                self.battery = battery
                self.features = features
            }
        }

        public struct Control: Codable, Equatable, Sendable {
            /// HID++ control ID, e.g. 0x0053.
            public var cid: UInt16
            /// The config name (`Config.Button`: middle, back, forward, gesture, top), else nil;
            /// config then uses the hex ID, e.g. "0x00c4".
            public var name: String?
            /// Whether the control can report raw XY movement (gestures). Nil when unknown.
            public var gestures: Bool?
            public init(cid: UInt16, name: String?, gestures: Bool? = nil) {
                self.cid = cid
                self.name = name
                self.gestures = gestures
            }
        }
    }

    public struct Capture: Codable, Equatable, Sendable {
        /// Echoes `Control.Capture.token`.
        public var token: Int
        public var state: State
        /// The control pressed, once `state` is `.pressed`.
        public var cid: UInt16?
        public var deviceID: String?
        /// The device key (`Device.model`) of the mouse whose control was pressed, once `state`
        /// is `.pressed` and the mouse has a key.
        public var model: String?
        public init(token: Int, state: State, cid: UInt16?, deviceID: String?, model: String? = nil) {
            self.token = token
            self.state = state
            self.cid = cid
            self.deviceID = deviceID
            self.model = model
        }
        public enum State: String, Codable, Sendable { case listening, pressed, timedOut, cancelled }
    }
}

/// Requests from the menu bar app. The daemon reads it on `Companion.controlNotification` and
/// deletes it when it starts, so a pause never outlives the daemon.
public struct Control: Codable, Equatable, Sendable {
    public var paused: Bool
    /// Present to start select-by-pressing; a new token starts a new capture, nil cancels one.
    public var capture: Capture?
    /// A new token drops the DPI chosen by `cycleDPI` and sets every mouse to the config's `dpi`:
    /// choosing the saved value leaves the file unchanged, so no reload would.
    public var useConfiguredDPI: Int?
    /// Aims `useConfiguredDPI` at the one mouse with this device key (`Status.Device.model`),
    /// leaving the others as they are. Nil means every mouse.
    public var device: String?

    public init(paused: Bool = false, capture: Capture? = nil, useConfiguredDPI: Int? = nil,
                device: String? = nil) {
        self.paused = paused
        self.capture = capture
        self.useConfiguredDPI = useConfiguredDPI
        self.device = device
    }

    public struct Capture: Codable, Equatable, Sendable {
        public var token: Int
        /// Listens on the one mouse with this device key only; nil means every mouse.
        public var device: String?
        public init(token: Int, device: String? = nil) {
            self.token = token
            self.device = device
        }
    }
}
