/// Typed wrappers for the HID++ 2.0 features PureMouse uses. Each wraps request/response layouts
/// only; policy lives in the daemon. Byte layouts follow Solaar's `hidpp20.py` and logiops.

/// 0x1B04 REPROG_CONTROLS_V4: button diversion, so presses arrive over HID++ instead of as clicks.
public enum ReprogControls {
    public static let id: UInt16 = 0x1B04

    public struct Control: Sendable {
        public let cid: UInt16
        public let flags: UInt8           // bit 5 (0x20): divertable; bit 7 (0x80): virtual
        public let additionalFlags: UInt8 // bit 0 (0x01): raw XY capable
        public var isDivertable: Bool { flags & 0x20 != 0 }
        /// No physical button (e.g. 0x00D7, the virtual gesture button), so it is never pressed.
        public var isVirtual: Bool { flags & 0x80 != 0 }
        public var supportsRawXY: Bool { additionalFlags & 0x01 != 0 }
    }

    public enum Event: Equatable, Sendable {
        /// The diverted controls currently held, in press order (up to four).
        case buttons([UInt16])
        /// Pointer motion while a raw-XY-diverted control is held. +x right, +y down.
        case rawXY(dx: Int16, dy: Int16)
    }

    public struct Reporting: Equatable, Sendable {
        public let cid: UInt16
        public let diverted: Bool
        public let persistent: Bool
        public let rawXY: Bool
    }

    /// getCidReporting (function 2): CID followed by diversion flags.
    public static func reporting(_ d: HIDPPDevice, cid: UInt16) async throws -> Reporting {
        guard let reporting = parseReporting(try await d.call(id, 2, cid.bigEndianBytes)),
              reporting.cid == cid else { throw HIDPPError.malformedResponse }
        return reporting
    }

    public static func parseReporting(_ params: [UInt8]) -> Reporting? {
        guard params.count >= 3 else { return nil }
        return Reporting(cid: UInt16(bigEndian: params[0], params[1]), diverted: params[2] & 1 != 0,
                         persistent: params[2] & 4 != 0, rawXY: params[2] & 0x10 != 0)
    }

    public static func controls(_ d: HIDPPDevice) async throws -> [Control] {
        guard let count = try await d.call(id, 0).first else { throw HIDPPError.malformedResponse }
        var controls: [Control] = []
        for i in 0..<count {
            let r = try await d.call(id, 1, [i])
            guard r.count >= 9 else { throw HIDPPError.malformedResponse }
            controls.append(Control(cid: UInt16(bigEndian: r[0], r[1]), flags: r[4], additionalFlags: r[8]))
        }
        return controls
    }

    /// Temporary (non-persistent) diversion; the device forgets it on power cycle or reconnect.
    public static func setDiverted(_ d: HIDPPDevice, cid: UInt16, divert: Bool, rawXY: Bool) async throws {
        let divertBits: UInt8 = (divert ? 0x01 : 0) | 0x02  // divert + divert-valid
        let rawXYBits: UInt8 = (rawXY ? 0x10 : 0) | 0x20    // rawXY + rawXY-valid
        _ = try await d.call(id, 3, cid.bigEndianBytes + [divertBits | rawXYBits])
    }

    public static func parse(function: UInt8, params: [UInt8]) -> Event? {
        switch function {
        case 0:
            let cids = stride(from: 0, to: min(params.count, 8) - 1, by: 2)
                .map { UInt16(bigEndian: params[$0], params[$0 + 1]) }
                .filter { $0 != 0 }
            return .buttons(cids)
        case 1 where params.count >= 4:
            return .rawXY(dx: Int16(bitPattern: UInt16(bigEndian: params[0], params[1])),
                          dy: Int16(bitPattern: UInt16(bigEndian: params[2], params[3])))
        default:
            return nil
        }
    }
}

/// 0x2110 SMART_SHIFT: the scroll wheel's ratchet/free-spin clutch.
public enum SmartShift {
    public static let id: UInt16 = 0x2110

    public enum Mode: UInt8, Sendable {
        case freespin = 1
        case ratchet = 2
    }

    public struct State: Sendable {
        public let mode: Mode
        /// SmartShift threshold (1–50): wheel speed at which ratchet disengages automatically.
        /// 0xFF means never, i.e. SmartShift off.
        public let autoDisengage: UInt8
    }

    public static func get(_ d: HIDPPDevice) async throws -> State {
        let r = try await d.call(id, 0)
        guard r.count >= 2, let mode = Mode(rawValue: r[0]) else { throw HIDPPError.malformedResponse }
        return State(mode: mode, autoDisengage: r[1])
    }

    /// Passing nil for `autoDisengage` leaves it unchanged.
    public static func set(_ d: HIDPPDevice, mode: Mode, autoDisengage: UInt8? = nil) async throws {
        _ = try await d.call(id, 1, [mode.rawValue, autoDisengage ?? 0])
    }
}

/// 0x2111 SMART_SHIFT_ENHANCED: MX Master 4 / Anywhere 3 family clutch.
/// Function numbers and layouts follow Solaar's SmartShiftEnhanced and ScrollRatchetTorque.
public enum SmartShiftEnhanced {
    public static let id: UInt16 = 0x2111

    public struct State: Equatable, Sendable {
        public let mode: SmartShift.Mode
        public let autoDisengage: UInt8
        public let torque: UInt8
    }

    public static func getRatchetControlMode(_ d: HIDPPDevice) async throws -> State {
        guard let state = parseRatchetControlMode(try await d.call(id, 1)) else {
            throw HIDPPError.malformedResponse
        }
        return state
    }

    public static func parseRatchetControlMode(_ params: [UInt8]) -> State? {
        guard params.count >= 3, let mode = SmartShift.Mode(rawValue: params[0]) else { return nil }
        return State(mode: mode, autoDisengage: params[1], torque: params[2])
    }

    /// Zero leaves threshold/torque unchanged, so torque is always written as zero. The mode is
    /// always supplied: on MX4 a torque change takes effect only when the ratchet mode is written
    /// with it (Solaar's MX4 quirk). Nil `autoDisengage` leaves the threshold unchanged.
    public static func setRatchetControlMode(_ d: HIDPPDevice, mode: SmartShift.Mode,
                                             autoDisengage: UInt8? = nil) async throws {
        _ = try await d.call(id, 2, parameters(mode: mode, autoDisengage: autoDisengage))
    }

    static func parameters(mode: SmartShift.Mode, autoDisengage: UInt8?) -> [UInt8] {
        [mode.rawValue, autoDisengage ?? 0, 0]
    }
}

/// 0x19B0 HAPTIC: host-triggered effects on the MX Master 4. Play only: deliberately exposes
/// no strength/enable/configuration write, whose persistence is not established.
public enum Haptic {
    public static let id: UInt16 = 0x19B0

    public struct Capabilities: Equatable, Sendable {
        /// Solaar PlayHapticWaveForm: bytes 4–7, big endian; bit N permits waveform N.
        public let supportedWaveforms: UInt32

        public func supports(_ waveform: UInt8) -> Bool {
            waveform < 32 && supportedWaveforms & (UInt32(1) << waveform) != 0
        }
    }

    public static func getCapabilities(_ d: HIDPPDevice) async throws -> Capabilities {
        guard let caps = parseCapabilities(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return caps
    }

    public static func parseCapabilities(_ params: [UInt8]) -> Capabilities? {
        guard params.count >= 8 else { return nil }
        let mask = params[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Capabilities(supportedWaveforms: mask)
    }

    public static func playWaveform(_ d: HIDPPDevice, waveform: UInt8) async throws {
        _ = try await d.call(id, 4, [waveform])
    }
}

/// 0x2201 ADJUSTABLE_DPI: sensor resolution.
public enum AdjustableDPI {
    public static let id: UInt16 = 0x2201

    /// The resolutions a sensor accepts, ascending.
    public struct Resolutions: Equatable, Sendable {
        public let values: [Int]

        public init(_ values: [Int]) {
            self.values = values
        }

        /// Decodes a DPI list of big-endian words ended by 0x0000 (or by the end of the bytes). A
        /// word with its top three bits set is a step (low 13 bits) between the values either
        /// side of it, so 200, step 50, 8000 means 200, 250, …, 8000. Nil if the list is empty or
        /// a step has no range. Shared by 0x2201 and 0x2202, which encode lists alike.
        init?(words bytes: ArraySlice<UInt8>) {
            let words = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2)
                .map { Int(UInt16(bigEndian: bytes[$0], bytes[$0 + 1])) }
                .prefix { $0 != 0 }
            var values: [Int] = []
            var step: Int?
            for word in words {
                if word & 0xE000 == 0xE000 {
                    guard step == nil, values.last != nil, word & 0x1FFF > 0 else { return nil }
                    step = word & 0x1FFF
                } else if let s = step {
                    guard let last = values.last, word > last else { return nil }
                    values += stride(from: last + s, through: word, by: s)
                    step = nil
                } else {
                    values.append(word)
                }
            }
            guard step == nil, !values.isEmpty else { return nil }
            self.init(values.sorted())
        }

        /// The supported resolution closest to `dpi`; the lower one on a tie.
        public func nearest(to dpi: Int) -> Int? {
            values.min { abs($0 - dpi) < abs($1 - dpi) }
        }
    }

    public static func resolutions(_ d: HIDPPDevice, sensor: UInt8 = 0) async throws -> Resolutions {
        let r = try await d.call(id, 1, [sensor])
        guard let resolutions = parseResolutions(r) else { throw HIDPPError.malformedResponse }
        return resolutions
    }

    /// getSensorDpiList reply: [sensor, big-endian words…, 0x0000]. See `Resolutions.init(words:)`.
    public static func parseResolutions(_ params: [UInt8]) -> Resolutions? {
        Resolutions(words: params.dropFirst())
    }

    public static func get(_ d: HIDPPDevice, sensor: UInt8 = 0) async throws -> Int {
        let r = try await d.call(id, 2, [sensor])
        guard r.count >= 3 else { throw HIDPPError.malformedResponse }
        return Int(UInt16(bigEndian: r[1], r[2]))
    }

    public static func set(_ d: HIDPPDevice, dpi: Int, sensor: UInt8 = 0) async throws {
        _ = try await d.call(id, 3, [sensor] + UInt16(clamping: dpi).bigEndianBytes)
    }
}

/// 0x2202 EXTENDED_ADJUSTABLE_DPI: resolution on mice without 0x2201 (the G Pro X 2 family), with
/// separate X and Y axes and a lift-off distance. Function numbers and layouts follow Solaar's
/// `ExtendedAdjustableDpi`, which assumes one sensor; no raw capture is public, so everything
/// here is checked against that layout and hand-built fixtures only.
public enum ExtendedDPI {
    public static let id: UInt16 = 0x2202

    public struct Capabilities: Equatable, Sendable {
        /// The Y axis has its own resolution and list.
        public let separateY: Bool
        /// The sensor has a lift-off distance setting.
        public let liftOffDistance: Bool
    }

    /// The sensor's resolution, as getDpi reports it (the X axis; the Y axis follows it on a write).
    public struct Reading: Equatable, Sendable {
        public let x: Int
        /// 0 low, 1 medium, 2 high; kept as read, so a write leaves it alone.
        public let liftOffDistance: UInt8
    }

    /// getCapabilities (function 1): bit 0 of byte 2 is a separate Y axis, bit 1 lift-off distance.
    public static func capabilities(_ d: HIDPPDevice) async throws -> Capabilities {
        guard let caps = parseCapabilities(try await d.call(id, 1)) else { throw HIDPPError.malformedResponse }
        return caps
    }

    public static func parseCapabilities(_ params: [UInt8]) -> Capabilities? {
        guard params.count >= 3 else { return nil }
        return Capabilities(separateY: params[2] & 0x01 != 0, liftOffDistance: params[2] & 0x02 != 0)
    }

    /// The resolutions both axes accept (the X list alone without a separate Y), from the first
    /// reply of each list only: the lists seen are a range, which fits one reply.
    public static func resolutions(_ d: HIDPPDevice, capabilities: Capabilities) async throws
        -> AdjustableDPI.Resolutions {
        let x = try await list(d, direction: 0)
        guard capabilities.separateY else { return x }
        let y = try await list(d, direction: 1)
        let common = x.values.filter(y.values.contains)
        guard !common.isEmpty else { throw HIDPPError.malformedResponse }
        return AdjustableDPI.Resolutions(common)
    }

    private static func list(_ d: HIDPPDevice, direction: UInt8) async throws -> AdjustableDPI.Resolutions {
        guard let list = parseResolutions(try await d.call(id, 2, [0, direction, 0])) else {
            throw HIDPPError.malformedResponse
        }
        return list
    }

    /// getDpiList (function 2) reply: three header bytes, then words as in 0x2201, ended by
    /// 0x0000. Nil without that terminator, since the rest of the list would be in a later reply.
    public static func parseResolutions(_ params: [UInt8]) -> AdjustableDPI.Resolutions? {
        let words = params.dropFirst(3)
        guard stride(from: words.startIndex, to: words.endIndex - 1, by: 2)
            .contains(where: { words[$0] == 0 && words[$0 + 1] == 0 }) else { return nil }
        return AdjustableDPI.Resolutions(words: words)
    }

    /// getDpi (function 5).
    public static func get(_ d: HIDPPDevice) async throws -> Reading {
        guard let reading = parseReading(try await d.call(id, 5)) else { throw HIDPPError.malformedResponse }
        return reading
    }

    /// [sensor, X, default X, Y, default Y, lift-off distance], big endian. A zero X means the
    /// default.
    public static func parseReading(_ params: [UInt8]) -> Reading? {
        guard params.count >= 10 else { return nil }
        func word(_ i: Int) -> Int { Int(UInt16(bigEndian: params[i], params[i + 1])) }
        let x = word(1) == 0 ? word(3) : word(1)
        guard x > 0 else { return nil }
        return Reading(x: x, liftOffDistance: params[9])
    }

    /// setDpi (function 6): [sensor, X, Y, lift-off distance]. Without a separate Y axis, Y is
    /// zero and the lift-off distance is `reading`'s; with one, both axes get `dpi`.
    public static func set(_ d: HIDPPDevice, dpi: Int, capabilities: Capabilities, keeping reading: Reading) async throws {
        _ = try await d.call(id, 6, parameters(dpi: dpi, capabilities: capabilities, keeping: reading))
    }

    static func parameters(dpi: Int, capabilities: Capabilities, keeping reading: Reading) -> [UInt8] {
        let value = UInt16(clamping: dpi)
        return [0] + value.bigEndianBytes + (capabilities.separateY ? value.bigEndianBytes : [0, 0])
            + [capabilities.liftOffDistance ? reading.liftOffDistance : 0]
    }
}

/// 0x2130 LOWRES_WHEEL: the main wheel of a mouse whose wheel has only whole notches (Lift,
/// Signature M650/M750, MX Ergo). Function numbers and layouts follow Solaar's `LowresMode`
/// (function 0 reads and function 1 writes the reporting byte, bit 0 set meaning "report to
/// HID++") and its `lowres_wheel_up`/`lowres_wheel_down` rules (the event is function 0, its
/// first byte a signed notch count). No raw capture of this feature is public.
public enum LowResWheel {
    public static let id: UInt16 = 0x2130

    public enum Event: Equatable, Sendable {
        /// Whole notches while diverted. Positive is away from the user (scroll up).
        case scroll(notches: Int)
    }

    /// Whether the wheel reports to HID++ software instead of as ordinary HID scrolling.
    public static func diverted(_ d: HIDPPDevice) async throws -> Bool {
        guard let bits = try await d.call(id, 0).first else { throw HIDPPError.malformedResponse }
        return bits & 0x01 != 0
    }

    /// Temporary, like 0x2121's: the mouse reports natively again after a power cycle or reconnect.
    public static func setDiverted(_ d: HIDPPDevice, _ diverted: Bool) async throws {
        _ = try await d.call(id, 1, [diverted ? 0x01 : 0x00])
    }

    public static func parse(function: UInt8, params: [UInt8]) -> Event? {
        guard function == 0, let notches = params.first, notches != 0 else { return nil }
        return .scroll(notches: Int(Int8(bitPattern: notches)))
    }
}

/// 0x2121 HIRES_WHEEL: whether the main wheel reports natively (as ordinary HID scroll) or to
/// HID++ software, and at what resolution.
public enum HiResWheel {
    public static let id: UInt16 = 0x2121

    public struct Mode: Equatable, Sendable {
        public var diverted: Bool
        public var highResolution: Bool
        public var inverted: Bool

        public init(diverted: Bool, highResolution: Bool, inverted: Bool) {
            self.diverted = diverted
            self.highResolution = highResolution
            self.inverted = inverted
        }

        // Mode bits: 0x01 report to HID++, 0x02 high resolution, 0x04 inverted.
        init(bits: UInt8) {
            self.init(diverted: bits & 0x01 != 0, highResolution: bits & 0x02 != 0, inverted: bits & 0x04 != 0)
        }

        var bits: UInt8 { (diverted ? 0x01 : 0) | (highResolution ? 0x02 : 0) | (inverted ? 0x04 : 0) }
    }

    public enum Event: Equatable, Sendable {
        /// Wheel movement while diverted. Positive is away from the user (scroll up).
        case scroll(delta: Int, highResolution: Bool)
        /// The ratchet clutch engaged (true) or released into free-spin (false).
        case ratchet(Bool)
    }

    /// High-resolution units per ratchet notch (15 on the MX Master 3S).
    public static func multiplier(_ d: HIDPPDevice) async throws -> Int {
        guard let m = try await d.call(id, 0).first, m > 0 else { throw HIDPPError.malformedResponse }
        return Int(m)
    }

    public static func mode(_ d: HIDPPDevice) async throws -> Mode {
        guard let bits = try await d.call(id, 1).first else { throw HIDPPError.malformedResponse }
        return Mode(bits: bits)
    }

    public static func setMode(_ d: HIDPPDevice, _ mode: Mode) async throws {
        _ = try await d.call(id, 2, [mode.bits])
    }

    public static func parse(function: UInt8, params: [UInt8]) -> Event? {
        switch function {
        case 0 where params.count >= 3:
            // [flags (0x10 high resolution, low nibble periods), deltaV int16 BE]
            return .scroll(delta: Int(Int16(bitPattern: UInt16(bigEndian: params[1], params[2]))),
                           highResolution: params[0] & 0x10 != 0)
        case 1 where params.count >= 1:
            return .ratchet(params[0] & 0x01 != 0)
        default:
            return nil
        }
    }
}

/// 0x2150 THUMB_WHEEL: the horizontal thumb wheel.
public enum ThumbWheel {
    public static let id: UInt16 = 0x2150

    public struct Info: Sendable {
        /// Units per full rotation when reporting natively (18) and when diverted (120).
        public let nativeResolution: Int
        public let divertedResolution: Int

        public init(nativeResolution: Int, divertedResolution: Int) {
            self.nativeResolution = nativeResolution
            self.divertedResolution = divertedResolution
        }
    }

    public struct Reporting: Equatable, Sendable {
        public var diverted: Bool
        public var inverted: Bool

        public init(diverted: Bool, inverted: Bool) {
            self.diverted = diverted
            self.inverted = inverted
        }
    }

    public enum Status: UInt8, Sendable {
        case inactive = 0, start, active, stop
    }

    public struct Event: Equatable, Sendable {
        public let rotation: Int
        public let status: Status?
    }

    public static func info(_ d: HIDPPDevice) async throws -> Info {
        let r = try await d.call(id, 0)
        guard r.count >= 4 else { throw HIDPPError.malformedResponse }
        let native = Int(UInt16(bigEndian: r[0], r[1])), diverted = Int(UInt16(bigEndian: r[2], r[3]))
        guard native > 0, diverted > 0 else { throw HIDPPError.malformedResponse }
        return Info(nativeResolution: native, divertedResolution: diverted)
    }

    public static func reporting(_ d: HIDPPDevice) async throws -> Reporting {
        let r = try await d.call(id, 1)
        guard r.count >= 2 else { throw HIDPPError.malformedResponse }
        return Reporting(diverted: r[0] & 0x01 != 0, inverted: r[1] & 0x01 != 0)
    }

    public static func setReporting(_ d: HIDPPDevice, _ reporting: Reporting) async throws {
        _ = try await d.call(id, 2, [reporting.diverted ? 1 : 0, reporting.inverted ? 1 : 0])
    }

    /// Diverted rotation event: [rotation int16 BE, timestamp u16, status, flags].
    public static func parse(function: UInt8, params: [UInt8]) -> Event? {
        guard function == 0, params.count >= 5 else { return nil }
        return Event(rotation: Int(Int16(bitPattern: UInt16(bigEndian: params[0], params[1]))),
                     status: Status(rawValue: params[4]))
    }
}

/// 0x1004 UNIFIED_BATTERY: charge and charging state. Layouts follow Solaar
/// (`decipher_battery_unified`) and Linux `hid-logitech-hidpp.c` (`hidpp20_unifiedbattery_*`).
public enum UnifiedBattery {
    public static let id: UInt16 = 0x1004

    public enum Level: Sendable { case critical, low, good, full }

    /// Charging status byte: 0 discharging, 1 charging, 2 charging slowly, 3 complete, 4 error.
    public enum Charging: UInt8, Sendable {
        case discharging = 0, charging, chargingSlowly, complete, error
    }

    public struct State: Equatable, Sendable {
        /// State of charge, 1–100; nil when the device reports only a level.
        public let percent: Int?
        public let level: Level?
        public let charging: Charging?
        public let externalPower: Bool

        public var isCharging: Bool { charging == .charging || charging == .chargingSlowly }
    }

    /// The level bits (8 full, 4 good, 2 low, 1 critical) a device's status reports mean
    /// anything for. As in Linux, a device that reports a state of charge has its levels ignored.
    public static let allLevels: UInt8 = 0x0F

    /// getCapabilities: [supported level bits, flags (1 rechargeable, 2 state of charge)].
    /// Returns the level bits to honour in status reports.
    public static func levels(_ d: HIDPPDevice) async throws -> UInt8 {
        guard let levels = parseCapabilities(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return levels
    }

    public static func parseCapabilities(_ params: [UInt8]) -> UInt8? {
        guard params.count >= 2 else { return nil }
        return params[1] & 0x02 != 0 ? 0 : params[0] & allLevels
    }

    /// getStatus, its level bits masked by `levels` (see `levels(_:)`).
    public static func status(_ d: HIDPPDevice, levels: UInt8 = allLevels) async throws -> State {
        guard let state = parseStatus(try await d.call(id, 1), levels: levels) else {
            throw HIDPPError.malformedResponse
        }
        return state
    }

    /// The broadcast status event (function 0), sent when charge or charging changes. Same
    /// layout as getStatus.
    public static func parse(function: UInt8, params: [UInt8], levels: UInt8 = allLevels) -> State? {
        function == 0 ? parseStatus(params, levels: levels) : nil
    }

    /// [state of charge %, level bits, charging status, external power]. A charge of 0 means the
    /// device reports levels only. Level bits outside `levels` are ignored, and of the rest the
    /// highest wins, as in Linux (hidpp20_unifiedbattery_map_level).
    public static func parseStatus(_ params: [UInt8], levels: UInt8 = allLevels) -> State? {
        guard params.count >= 4, params[0] <= 100 else { return nil }
        let bits = params[1] & levels
        let level: Level? = bits & 0x08 != 0 ? .full : bits & 0x04 != 0 ? .good
            : bits & 0x02 != 0 ? .low : bits & 0x01 != 0 ? .critical : nil
        return State(percent: params[0] == 0 ? nil : Int(params[0]), level: level,
                     charging: Charging(rawValue: params[2]), externalPower: params[3] != 0)
    }
}

/// 0x1000 BATTERY_LEVEL_STATUS: older firmware's read-only battery reporting.
/// Solaar `decipher_battery_status` / `common.BatteryStatus`; function 0 is both get and event.
public enum LegacyBattery {
    public static let id: UInt16 = 0x1000

    public static func status(_ d: HIDPPDevice) async throws -> UnifiedBattery.State {
        guard let state = parseStatus(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return state
    }

    public static func parse(function: UInt8, params: [UInt8]) -> UnifiedBattery.State? {
        function == 0 ? parseStatus(params) : nil
    }

    /// [percent, next threshold percent, status]. Zero percent is unknown, not empty.
    /// Status 2 is almost full (still charging), 4 slow recharge, 5/6 battery/thermal error;
    /// these differ from 0x1004. Never substitute the next threshold for the current charge.
    public static func parseStatus(_ params: [UInt8]) -> UnifiedBattery.State? {
        guard params.count >= 3, params[0] <= 100 else { return nil }
        let charging: UnifiedBattery.Charging?
        switch params[2] {
        case 0: charging = .discharging
        case 1, 2: charging = .charging
        case 3: charging = .complete
        case 4: charging = .chargingSlowly
        case 5, 6: charging = .error
        default: charging = nil
        }
        // As in Solaar, infer a level from charging state only when percentage is unavailable.
        let level: UnifiedBattery.Level? = params[0] != 0 ? nil
            : params[2] == 3 ? .full : params[2] == 1 || params[2] == 2 ? .good
            : params[2] == 4 ? .low : nil
        return UnifiedBattery.State(percent: params[0] == 0 ? nil : Int(params[0]), level: level,
                                    charging: charging, externalPower: (1...4).contains(params[2]))
    }
}

/// 0x1001 BATTERY_VOLTAGE: older gaming mice report millivolts, not a percentage. Function 0 is
/// both the read and the broadcast event: [millivolts (big endian), flags]. Layout from Solaar
/// (`decipher_battery_voltage`) and the Linux driver (`hidpp20_battery_map_status_voltage`),
/// which agree; the flags' low bits are read as the driver does (0 charging, 1 full).
public enum BatteryVoltage {
    public static let id: UInt16 = 0x1001

    public static func status(_ d: HIDPPDevice) async throws -> UnifiedBattery.State {
        guard let state = parseStatus(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return state
    }

    public static func parse(function: UInt8, params: [UInt8]) -> UnifiedBattery.State? {
        function == 0 ? parseStatus(params) : nil
    }

    /// A level, never a percentage: no curve fits every battery (the driver says so), so the
    /// millivolts are banded at the points where the driver's and Solaar's curves both read
    /// 80 %, 30 % and 10 %. Flags: 0x80 on external power, then 1 full, 0 charging, 2 not
    /// charging; 0x10 slow charge; 0x20 critical.
    public static func parseStatus(_ params: [UInt8]) -> UnifiedBattery.State? {
        guard params.count >= 3 else { return nil }
        let millivolts = Int(UInt16(bigEndian: params[0], params[1]))
        let flags = params[2]
        let external = flags & 0x80 != 0
        let charging: UnifiedBattery.Charging? = !external ? .discharging
            : flags & 0x07 == 1 ? .complete : flags & 0x07 == 0 ? (flags & 0x10 != 0 ? .chargingSlowly : .charging) : nil
        let level: UnifiedBattery.Level = charging == .complete ? .full : flags & 0x20 != 0 ? .critical
            : millivolts >= 3989 ? .full : millivolts >= 3751 ? .good : millivolts >= 3671 ? .low : .critical
        return UnifiedBattery.State(percent: nil, level: level, charging: charging, externalPower: external)
    }
}

/// 0x0005 DEVICE_NAME: the marketing name, e.g. "MX Master 3S".
public enum DeviceName {
    public static let id: UInt16 = 0x0005

    public static func get(_ d: HIDPPDevice) async throws -> String {
        guard let length = try await d.call(id, 0).first else { return "" }
        var bytes: [UInt8] = []
        while bytes.count < Int(length) {
            let chunk = try await d.call(id, 1, [UInt8(bytes.count)])
            guard !chunk.isEmpty else { break }
            bytes += chunk.prefix(Int(length) - bytes.count)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// getDeviceType's answer (Solaar `DEVICE_KIND`).
    public enum Kind: UInt8, CaseIterable, Sendable {
        case keyboard, remote, numpad, mouse, touchpad, trackball, presenter, receiver

        /// The word for it, as the status reports it.
        public var name: String { "\(self)" }
    }

    /// Function 2, getDeviceType; nil for a type this table does not name.
    public static func kind(_ d: HIDPPDevice) async throws -> Kind? {
        guard let code = try await d.call(id, 2).first else { throw HIDPPError.malformedResponse }
        return Kind(rawValue: code)
    }
}

/// 0x0003 DEVICE_FW_VERSION getDeviceInfo: the unit ID and the product IDs for the device's
/// transports. Solaar Hidpp20.get_ids: unit ID at bytes 1–4, transport flags at byte 6, up to
/// three IDs at bytes 7–12, which together are the model ID.
public enum DeviceIdentity {
    public static let id: UInt16 = 0x0003

    /// The identity fields of a getDeviceInfo reply, as the device sends them.
    public struct Info: Equatable, Sendable {
        /// Stable for one physical device.
        public var unitID: [UInt8]
        /// Bytes 7–12: the same for every device of one model, whatever the connection.
        public var modelID: [UInt8]

        public init(unitID: [UInt8], modelID: [UInt8]) {
            self.unitID = unitID
            self.modelID = modelID
        }
    }

    public static func info(_ d: HIDPPDevice) async throws -> Info {
        guard let info = parseInfo(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return info
    }

    public static func parseInfo(_ params: [UInt8]) -> Info? {
        guard params.count >= 13 else { return nil }
        return Info(unitID: Array(params[1...4]), modelID: Array(params[7...12]))
    }

    public enum Transport: UInt8, CaseIterable, Sendable {
        case bluetooth = 1, bluetoothLE = 2, wireless = 4, usb = 8
    }

    public static func transportIDs(_ d: HIDPPDevice) async throws -> [Transport: UInt16] {
        guard let ids = parseTransportIDs(try await d.call(id, 0)) else { throw HIDPPError.malformedResponse }
        return ids
    }

    public static func parseTransportIDs(_ params: [UInt8]) -> [Transport: UInt16]? {
        guard params.count >= 13 else { return nil }
        var ids: [Transport: UInt16] = [:]
        var offset = 7
        for transport in Transport.allCases where params[6] & transport.rawValue != 0 {
            guard offset + 1 < 13 else { return nil }
            ids[transport] = UInt16(bigEndian: params[offset], params[offset + 1])
            offset += 2
        }
        return ids
    }
}

/// 0x1D4B WIRELESS_DEVICE_STATUS: the device announces that it has reconnected and that host
/// software should re-apply its settings.
public enum WirelessDeviceStatus {
    public static let id: UInt16 = 0x1D4B

    /// True for the broadcast status event when it reports a reconnection or asks for
    /// reconfiguration. Params: [reconnection, reconfigurationNeeded, powerSwitch].
    public static func needsReconfiguration(function: UInt8, params: [UInt8]) -> Bool {
        function == 0 && params.count >= 2 && (params[0] == 1 || params[1] == 1)
    }
}

/// HID++ 1.0 receiver plumbing (Bolt and Unifying).
public enum Receiver {
    /// Sub-ID of the "device connected/disconnected" notification sent for a slot.
    public static let connectionNotification: UInt8 = 0x41

    /// For a 0x41 notification, whether the link is up. Bit 6 of the flags byte is "link not
    /// established". The flags byte is report byte 4, which `Report` parses as `params[0]`.
    public static func isLinkEstablished(_ report: Report) -> Bool {
        guard let flags = report.params.first else { return false }
        return flags & 0x40 == 0
    }

    /// For a 0x41 notification, the wireless product ID of the slot's device (little-endian,
    /// `params[1...2]`), which changes when a different device is paired into the slot.
    public static func productID(_ report: Report) -> UInt16? {
        guard report.params.count >= 3 else { return nil }
        return UInt16(report.params[2]) << 8 | UInt16(report.params[1])
    }

    /// Enables wireless (connect/disconnect) notifications and marks HID++ software present.
    public static func enableNotifications(_ receiver: HIDPPDevice) async throws {
        // SET_REGISTER (0x80) register 0x00, 3-byte flags: wireless 0x000100 | software 0x000800.
        _ = try await receiver.registerRequest(subID: 0x80, register: 0x00, params: [0x00, 0x09, 0x00])
    }
}
