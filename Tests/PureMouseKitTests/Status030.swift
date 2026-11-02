import Foundation

// A frozen copy of the Status and Control types as 0.3.0 shipped them (tag v0.3.0; the Kit is
// unchanged since), renamed so they sit beside the current ones. A menu or daemon built from 0.3.0 decodes exactly this, so decoding
// whatever the current daemon writes with these types is the additive-contract check
// (docs/companion.md, Versioning). Never edit the types below; they stand for a released version.

/// What the daemon is doing, rewritten whenever any of it changes.
struct Status030: Codable, Equatable, Sendable {
    /// Bumped on incompatible changes; a reader seeing a newer version shows "update PureMouse".
    static let currentSchema = 1

    var schema = Status030.currentSchema
    var pid: Int32
    var startedAt: Date
    /// The daemon's bundle version ("dev" for a `swift build` binary).
    var version: String
    /// False only in the final status written while shutting down.
    var running: Bool
    /// Paused through `Control.paused`: every mouse is back to native behaviour.
    var paused: Bool
    var permissions: Permissions
    /// A Logi Options+ process is running and will fight PureMouse over the mouse.
    var logiOptionsRunning: Bool
    var config: ConfigState
    var devices: [Device]
    /// The current or most recent select-by-pressing request.
    var capture: Capture?
    /// True while the pointer is on another Mac (Universal Control) and the mice are handed back
    /// to macOS for it. Absent from older daemons.
    var away: Bool?

    init(pid: Int32, startedAt: Date, version: String, running: Bool, paused: Bool,
                permissions: Permissions, logiOptionsRunning: Bool, config: ConfigState,
                devices: [Device], capture: Capture?, away: Bool? = nil) {
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

    struct Permissions: Codable, Equatable, Sendable {
        var accessibility: Bool
        var inputMonitoring: Bool
        init(accessibility: Bool, inputMonitoring: Bool) {
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
        }
    }

    struct ConfigState: Codable, Equatable, Sendable {
        var path: String
        /// Why the last load failed, while the daemon keeps running on the previous config.
        var error: String?
        init(path: String, error: String?) {
            self.path = path
            self.error = error
        }
    }

    struct Device: Codable, Equatable, Sendable {
        /// Stable while the daemon runs: interface plus device index.
        var id: String
        var name: String
        var connection: Connection
        /// Connected and answering; false while asleep or switched off.
        var online: Bool
        var battery: Battery?
        /// The DPI the sensor is set to now, if read.
        var dpi: Int?
        /// Every DPI the sensor accepts, ascending; empty if it could not be read.
        var dpiSteps: [Int]
        var wheelMode: WheelMode?
        var hasSmartShift: Bool
        var hasThumbWheel: Bool
        /// Controls (buttons) the mouse can hand to PureMouse.
        var controls: [Control]

        init(id: String, name: String, connection: Connection, online: Bool, battery: Battery?,
                    dpi: Int?, dpiSteps: [Int], wheelMode: WheelMode?, hasSmartShift: Bool,
                    hasThumbWheel: Bool, controls: [Control]) {
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
        }

        enum Connection: String, Codable, Sendable { case receiver, bluetooth }
        enum WheelMode: String, Codable, Sendable { case ratchet, freespin }

        struct Battery: Codable, Equatable, Sendable {
            /// 0–100, when the mouse reports a percentage.
            var percent: Int?
            var level: Level
            var charging: Bool
            init(percent: Int?, level: Level, charging: Bool) {
                self.percent = percent
                self.level = level
                self.charging = charging
            }
            enum Level: String, Codable, Sendable { case full, good, low, critical }
        }

        struct Control: Codable, Equatable, Sendable {
            /// HID++ control ID, e.g. 0x0053.
            var cid: UInt16
            /// The config name (`Config.Button`: middle, back, forward, gesture, top), else nil;
            /// config then uses the hex ID, e.g. "0x00c4".
            var name: String?
            init(cid: UInt16, name: String?) {
                self.cid = cid
                self.name = name
            }
        }
    }

    struct Capture: Codable, Equatable, Sendable {
        /// Echoes `Control.Capture.token`.
        var token: Int
        var state: State
        /// The control pressed, once `state` is `.pressed`.
        var cid: UInt16?
        var deviceID: String?
        init(token: Int, state: State, cid: UInt16?, deviceID: String?) {
            self.token = token
            self.state = state
            self.cid = cid
            self.deviceID = deviceID
        }
        enum State: String, Codable, Sendable { case listening, pressed, timedOut, cancelled }
    }
}

/// Requests from the menu bar app. The daemon reads it on `Companion.controlNotification` and
/// deletes it when it starts, so a pause never outlives the daemon.
struct Control030: Codable, Equatable, Sendable {
    var paused: Bool
    /// Present to start select-by-pressing; a new token starts a new capture, nil cancels one.
    var capture: Capture?
    /// A new token drops the DPI chosen by `cycleDPI` and sets every mouse to the config's `dpi`:
    /// choosing the saved value leaves the file unchanged, so no reload would.
    var useConfiguredDPI: Int?

    init(paused: Bool = false, capture: Capture? = nil, useConfiguredDPI: Int? = nil) {
        self.paused = paused
        self.capture = capture
        self.useConfiguredDPI = useConfiguredDPI
    }

    struct Capture: Codable, Equatable, Sendable {
        var token: Int
        init(token: Int) { self.token = token }
    }
}
