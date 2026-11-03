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

    /// `PUREMOUSE_COMPANION_DIR` in `environment`, the one place it is parsed; empty counts as unset.
    public static func overrideDirectory(in environment: [String: String]) -> String? {
        guard let dir = environment["PUREMOUSE_COMPANION_DIR"], !dir.isEmpty else { return nil }
        return dir
    }

    /// This process's `overrideDirectory(in:)`.
    public static let overrideDirectory = overrideDirectory(in: ProcessInfo.processInfo.environment)

    /// `~/Library/Application Support/PureMouse`, or `overrideDirectory` when set (tests and
    /// development, so a fixture never collides with an installed daemon).
    public static var directory: URL {
        if let dir = overrideDirectory { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/PureMouse")
    }
    /// Written by the daemon: `Status`.
    public static var statusURL: URL { directory.appending(path: "status.json") }
    /// Written by the menu bar app: `Control`.
    public static var controlURL: URL { directory.appending(path: "control.json") }
    /// The marker `menu off` leaves in `directory` and `menu on` removes: the icon is hidden. The
    /// daemon writes it and the menu bar app reads it, each naming the path from this.
    public static let menuHiddenName = "menu-hidden"
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

    /// A doorbell's name: `base`, with a short hash of the fixture directory appended when there is
    /// one, so a development copy never rings an installed app's bell. The hash is of the resolved
    /// path (symlinks followed, no trailing slash), so every spelling of a directory rings the same
    /// bell. Without a directory the name is `base`. The hash is FNV-1a, which (unlike `hashValue`)
    /// is the same in every process.
    public static func doorbell(_ base: String, directory: String? = overrideDirectory) -> String {
        guard let directory else { return base }
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        return base + "." + fnv1a(resolved)
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", hash)
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
    public static let currentSchema = 3

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
    /// Bluetooth mice the daemon has seen but cannot talk to until Input Monitoring is allowed.
    /// Absent from a daemon older than this field; read it as empty (`waiting`). The schema did not
    /// change: a reader that does not know the field ignores it.
    public var waitingForInputMonitoring: [WaitingDevice]?

    /// `waitingForInputMonitoring`, empty when the daemon does not say.
    public var waiting: [WaitingDevice] { waitingForInputMonitoring ?? [] }

    public init(pid: Int32, startedAt: Date, version: String, running: Bool, paused: Bool,
                permissions: Permissions, logiOptionsRunning: Bool, config: ConfigState,
                devices: [Device], capture: Capture?, away: Bool = false,
                waitingForInputMonitoring: [WaitingDevice]? = nil) {
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
        self.waitingForInputMonitoring = waitingForInputMonitoring
    }

    /// A Bluetooth device whose name macOS shows but whose replies it holds back without Input
    /// Monitoring, so PureMouse cannot tell what it is or configure it.
    public struct WaitingDevice: Codable, Equatable, Sendable {
        /// Stable while the daemon runs: the interface's number.
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
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
        /// What the mouse reports it can do, once it has been configured; nil before. A member
        /// that is nil is unknown (not false), and a reader treats it as available.
        public var capabilities: Capabilities?
        /// Whether PureMouse's settings are on the mouse now (docs/how-it-works.md, "Sessions").
        /// Nil: the daemon does not say, and a reader shows nothing about it.
        public var applied: Applied?
        /// The main firmware as the mouse reports it ("RBM 22.01 B0015"); nil when it does not.
        public var firmware: String?
        /// The Easy-Switch hosts, where the mouse reports them; nil when it does not.
        public var hosts: Hosts?

        public init(id: String, name: String, connection: Connection, online: Bool, battery: Battery?,
                    dpi: Int?, dpiSteps: [Int], wheelMode: WheelMode?, controls: [Control],
                    model: String? = nil, unit: String? = nil,
                    kind: String? = nil, capabilities: Capabilities? = nil,
                    applied: Applied? = nil, firmware: String? = nil, hosts: Hosts? = nil) {
            self.id = id
            self.name = name
            self.connection = connection
            self.online = online
            self.battery = battery
            self.dpi = dpi
            self.dpiSteps = dpiSteps
            self.wheelMode = wheelMode
            self.controls = controls
            self.model = model
            self.unit = unit
            self.kind = kind
            self.capabilities = capabilities
            self.applied = applied
            self.firmware = firmware
            self.hosts = hosts
        }

        /// Whether a setting that needs `capability` applies to this mouse: unless it is known to
        /// lack it, so an unknown capability shows as available.
        public func offers(_ capability: KeyPath<Capabilities, Bool?>) -> Bool {
            capabilities?[keyPath: capability] != false
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

        /// The applied state of one mouse. Written on a change of state only, never on a clock.
        public struct Applied: Codable, Equatable, Sendable {
            /// `applying`: an apply is under way. `applied`: it finished for the current config.
            /// `notApplied`: the retries are spent; Apply Settings Again starts a fresh one.
            public var state: State
            /// When the apply finished, for `applied`; nil otherwise.
            public var at: Date?
            public init(state: State, at: Date? = nil) {
                self.state = state
                self.at = at
            }
            public enum State: String, Codable, Sendable { case applying, applied, notApplied }
        }

        /// The Easy-Switch slots as the mouse reports them.
        public struct Hosts: Codable, Equatable, Sendable {
            /// Zero-based index into `slots`; nil when the mouse does not say.
            public var current: Int?
            public var slots: [Slot]
            public init(current: Int?, slots: [Slot]) {
                self.current = current
                self.slots = slots
            }

            public struct Slot: Codable, Equatable, Sendable {
                /// The name the computer gave the mouse; nil where the mouse does not report one.
                public var name: String?
                /// False for an empty slot; nil where the mouse does not say.
                public var paired: Bool?
                public init(name: String? = nil, paired: Bool? = nil) {
                    self.name = name
                    self.paired = paired
                }
            }
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

            public init(dpi: Bool? = nil, smartShift: Bool? = nil, smoothScroll: Bool? = nil,
                        thumbWheel: Bool? = nil, haptics: Bool? = nil, battery: Bool? = nil) {
                self.dpi = dpi
                self.smartShift = smartShift
                self.smoothScroll = smoothScroll
                self.thumbWheel = thumbWheel
                self.haptics = haptics
                self.battery = battery
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
    /// leaving the others as they are. Nil means every mouse. Lowercased when set or decoded, as
    /// device keys are, so it compares exactly.
    public var device: String?
    /// A new token starts a fresh apply on every mouse whose settings are not applied (Apply
    /// Settings Again), or on the one that `device` names.
    public var reapply: Int?

    public init(paused: Bool = false, capture: Capture? = nil, useConfiguredDPI: Int? = nil,
                device: String? = nil, reapply: Int? = nil) {
        self.paused = paused
        self.capture = capture
        self.useConfiguredDPI = useConfiguredDPI
        self.device = device?.lowercased()
        self.reapply = reapply
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(paused: try c.decode(Bool.self, forKey: .paused),
                  capture: try c.decodeIfPresent(Capture.self, forKey: .capture),
                  useConfiguredDPI: try c.decodeIfPresent(Int.self, forKey: .useConfiguredDPI),
                  device: try c.decodeIfPresent(String.self, forKey: .device),
                  reapply: try c.decodeIfPresent(Int.self, forKey: .reapply))
    }

    public struct Capture: Codable, Equatable, Sendable {
        public var token: Int
        /// Listens on the one mouse with this device key only; nil means every mouse. Lowercased
        /// as `Control.device` is.
        public var device: String?
        public init(token: Int, device: String? = nil) {
            self.token = token
            self.device = device?.lowercased()
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(token: try c.decode(Int.self, forKey: .token),
                      device: try c.decodeIfPresent(String.self, forKey: .device))
        }
    }
}
