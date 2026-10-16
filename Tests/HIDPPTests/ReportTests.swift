import Testing
@testable import HIDPP

@Suite struct ReportTests {
    @Test func encodesLongReportPadded() {
        let r = Report(deviceIndex: 2, featureIndex: 0x09, function: 3, softwareID: 0xD, params: [0x00, 0xC3, 0x33])
        #expect(r.bytes.count == 20)
        #expect(Array(r.bytes.prefix(7)) == [0x11, 0x02, 0x09, 0x3D, 0x00, 0xC3, 0x33])
        #expect(r.bytes.dropFirst(7).allSatisfy { $0 == 0 })
    }

    @Test func roundTrips() {
        let r = Report(reportID: .short, deviceIndex: 0xFF, featureIndex: 0x80, function: 0, softwareID: 0, params: [0, 9, 0])
        #expect(Report(bytes: r.bytes) == r)
    }

    @Test func rejectsNonHIDPPReports() {
        #expect(Report(bytes: [0x02, 0x00, 0x01, 0x00]) == nil)
        #expect(Report(bytes: [0x11, 0x01]) == nil)
    }

    @Test func matchesResponseAndError20() {
        let req = Report(deviceIndex: 2, featureIndex: 0x0E, function: 1, softwareID: 0xD, params: [2])
        let ok = Report(bytes: [0x11, 0x02, 0x0E, 0x1D, 0x02])!
        #expect(req.isAnswered(by: ok))
        let err = Report(bytes: [0x11, 0x02, 0xFF, 0x0E, 0x1D, 0x05, 0, 0])!
        #expect(err.error(for: req) == .protocol20(code: 5))
        let otherSoftware = Report(bytes: [0x11, 0x02, 0xFF, 0x0E, 0x1A, 0x05])!
        #expect(otherSoftware.error(for: req) == nil)
    }

    /// Only events reach a session: another program's reply must not, even at a feature index
    /// in the HID++ 1.0 notification range.
    @Test func eventsAreTwoPointZeroEventsOrShortNotifications() {
        let otherReply = Report(bytes: [0x11, 0x02, 0x41, 0x02, 0x01, 0x02, 0x03])!  // swid 2
        #expect(!otherReply.isEvent)
        let unifyingConnection = Report(bytes: [0x10, 0x02, 0x41, 0x04, 0x02, 0x34, 0xB0])!  // byte 3: 0x04
        #expect(unifyingConnection.isEvent)
        let boltConnection = Report(bytes: [0x10, 0x02, 0x41, 0x10, 0x02, 0x34, 0xB0])!
        #expect(boltConnection.isEvent)
        let buttons = Report(bytes: [0x11, 0x02, 0x08, 0x00, 0x00, 0xC3])!  // swid 0
        #expect(buttons.isEvent)
        #expect(!Report(bytes: [0x11, 0x02, 0x08, 0x0A, 0x00, 0xC3])!.isEvent)  // a reply, swid 0xA
        #expect(!Report(bytes: [0x10, 0x02, 0x08, 0x13, 0x00, 0xC3])!.isEvent)
    }

    @Test func matchesError10() {
        let req = Report(reportID: .short, deviceIndex: 0xFF, featureIndex: 0x80, function: 0, softwareID: 0, params: [0, 9, 0])
        let err = Report(bytes: [0x10, 0xFF, 0x8F, 0x80, 0x00, 0x03, 0x00])!
        #expect(err.error(for: req) == .protocol10(code: 3))
    }
}

@Suite struct FeatureParsingTests {
    @Test func deviceTransportIDsDoNotConfuseReceiverAndMouse() {
        // Solaar get_ids layout: flags 0x06 = BLE then Unifying wireless, not fixed slots.
        let ids = DeviceIdentity.parseTransportIDs([4, 0, 0, 0, 0, 0, 6, 0xB0, 0x23, 0x40, 0x82, 0, 0])
        #expect(ids?[.bluetoothLE] == 0xB023 && ids?[.wireless] == 0x4082 && ids?[.usb] == nil)
        #expect(DeviceIdentity.parseTransportIDs([4, 0, 0, 0, 0, 0, 2, 0xB0, 0x42, 0, 0, 0, 0])?[.bluetoothLE] == 0xB042)
        #expect(DeviceIdentity.parseTransportIDs([4, 0, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0]) == nil)
        #expect(DeviceIdentity.parseTransportIDs([4, 0, 0, 0, 0, 0, 2, 0xB0, 0x42]) == nil)
    }

    @Test func parsesDivertedButtons() {
        let event = ReprogControls.parse(function: 0, params: [0x00, 0xC3, 0x00, 0x53, 0, 0, 0, 0, 0, 0])
        #expect(event == .buttons([0xC3, 0x53]))
        #expect(ReprogControls.parse(function: 0, params: Array(repeating: 0, count: 16)) == .buttons([]))
    }

    @Test func parsesSignedRawXY() {
        let event = ReprogControls.parse(function: 1, params: [0xFF, 0xF6, 0x00, 0x05])
        #expect(event == .rawXY(dx: -10, dy: 5))
    }

    @Test func connectionNotificationLinkBit() {
        let up = Report(bytes: [0x10, 0x02, 0x41, 0x10, 0x02, 0x34, 0xB0])!
        let down = Report(bytes: [0x10, 0x02, 0x41, 0x10, 0x42, 0x34, 0xB0])!
        #expect(Receiver.isLinkEstablished(up))
        #expect(!Receiver.isLinkEstablished(down))
        #expect(Receiver.productID(up) == 0xB034 && Receiver.productID(down) == 0xB034)  // MX Master 3S
        #expect(Receiver.productID(Report(bytes: [0x10, 0x02, 0x41, 0x10, 0x02])!) == nil)
    }
}

struct WheelEventTests {
    @Test func hiResScroll() {
        #expect(HiResWheel.parse(function: 0, params: [0x11, 0xFF, 0xF1]) == .scroll(delta: -15, highResolution: true))
        #expect(HiResWheel.parse(function: 0, params: [0x01, 0x00, 0x03]) == .scroll(delta: 3, highResolution: false))
    }

    @Test func ratchetSwitch() {
        #expect(HiResWheel.parse(function: 1, params: [0x01]) == .ratchet(true))
        #expect(HiResWheel.parse(function: 1, params: [0x00]) == .ratchet(false))
    }

    @Test func thumbRotation() {
        let event = ThumbWheel.parse(function: 0, params: [0xFF, 0xFE, 0x12, 0x34, 0x02, 0x00])
        #expect(event == ThumbWheel.Event(rotation: -2, status: .active))
        #expect(ThumbWheel.parse(function: 0, params: [0, 1]) == nil)
    }
}

struct BatteryTests {
    @Test func legacyStatusUsesItsOwnChargingCodes() throws {
        // Solaar hidpp20.decipher_battery_status: percent, next threshold, status.
        let discharging = try #require(LegacyBattery.parseStatus([45, 20, 0]))
        #expect(discharging.percent == 45 && !discharging.isCharging && !discharging.externalPower)
        #expect(LegacyBattery.parseStatus([45, 20, 2])?.charging == .charging) // almost full
        #expect(LegacyBattery.parseStatus([45, 20, 4])?.charging == .chargingSlowly)
        #expect(LegacyBattery.parseStatus([45, 20, 5])?.charging == .error)
        #expect(LegacyBattery.parseStatus([45, 20, 6])?.charging == .error)
        #expect(LegacyBattery.parseStatus([45, 20, 0xFF])?.charging == nil)
    }

    @Test func legacyUnknownChargeAndBroadcasts() throws {
        let unknown = try #require(LegacyBattery.parse(function: 0, params: [0, 20, 0]))
        #expect(unknown.percent == nil && unknown.level == nil)
        let full = try #require(LegacyBattery.parseStatus([0, 0, 3]))
        #expect(full.percent == nil && full.level == .full && full.charging == .complete)
        #expect(LegacyBattery.parseStatus([0, 0, 1])?.level == .good)
        #expect(LegacyBattery.parseStatus([0, 0, 4])?.level == .low)
        #expect(LegacyBattery.parse(function: 1, params: [45, 20, 0]) == nil)
        #expect(LegacyBattery.parseStatus([45, 20]) == nil)
        #expect(LegacyBattery.parseStatus([101, 20, 0]) == nil)
    }

    @Test func statusAsTheMXMaster3SAnswers() throws {
        // 45 %, good, discharging, no external power.
        let state = try #require(UnifiedBattery.parseStatus([0x2D, 0x04, 0x00, 0x00, 0, 0, 0, 0]))
        #expect(state == UnifiedBattery.State(percent: 45, level: .good, charging: .discharging, externalPower: false))
        #expect(!state.isCharging)
    }

    @Test func chargingAndLevelsOnly() throws {
        let charging = try #require(UnifiedBattery.parse(function: 0, params: [0x00, 0x02, 0x02, 0x01]))
        #expect(charging.percent == nil && charging.level == .low && charging.isCharging && charging.externalPower)
        let full = try #require(UnifiedBattery.parseStatus([100, 0x08, 0x03, 0x01]))
        #expect(full.level == .full && full.charging == .complete && !full.isCharging)
        #expect(UnifiedBattery.parseStatus([10, 0x03, 0x00, 0x00])?.level == .low)  // highest bit wins
    }

    @Test func levelsAreMaskedByCapabilities() throws {
        // Levels only, supporting critical, low and full.
        let levels = try #require(UnifiedBattery.parseCapabilities([0x0B, 0x01]))
        #expect(levels == 0x0B)
        #expect(UnifiedBattery.parseStatus([0, 0x06, 0x00, 0x00], levels: levels)?.level == .low)
        #expect(UnifiedBattery.parse(function: 0, params: [0, 0x04, 0x00, 0x00], levels: levels)?.level == nil)
        // A state of charge: levels are ignored and the percentage stands alone.
        #expect(UnifiedBattery.parseCapabilities([0x0F, 0x03]) == 0)
        let soc = try #require(UnifiedBattery.parseStatus([0x2D, 0x04, 0x00, 0x00], levels: 0))
        #expect(soc.percent == 45 && soc.level == nil)
        #expect(UnifiedBattery.parseCapabilities([0x0F]) == nil)
    }

    @Test func rejectsOtherFunctionsAndShortOrBadReports() {
        #expect(UnifiedBattery.parse(function: 1, params: [0x2D, 0x04, 0x00, 0x00]) == nil)
        #expect(UnifiedBattery.parseStatus([0x2D, 0x04]) == nil)
        #expect(UnifiedBattery.parseStatus([200, 0x04, 0x00, 0x00]) == nil)
    }
}

struct EnhancedSmartShiftTests {
    @Test func statusFromOpenLogiHardwareFixtures() throws {
        // AprilNEA/OpenLogi fixtures/devices/{mx-master-4-001,mx-anywhere-3s-001}/
        // cases/smartshift-status.json (MIT), response parameters of function 1.
        let master = try #require(SmartShiftEnhanced.parseRatchetControlMode([0x02, 0xFF, 0x4B, 0, 0]))
        #expect(master.mode == .ratchet && master.autoDisengage == 255 && master.torque == 75)
        let anywhere = try #require(SmartShiftEnhanced.parseRatchetControlMode([0x02, 0x0C, 0x32, 0]))
        #expect(anywhere.mode == .ratchet && anywhere.autoDisengage == 12 && anywhere.torque == 50)
        #expect(SmartShiftEnhanced.parseRatchetControlMode([1, 10, 50])?.mode == .freespin)
        #expect(SmartShiftEnhanced.parseRatchetControlMode([0, 10, 50]) == nil)
        #expect(SmartShiftEnhanced.parseRatchetControlMode([2, 10]) == nil)
    }

    @Test func writesLeaveTorqueUnchanged() {
        // Solaar ScrollRatchetTorque: write [mode, threshold, torque], zero meaning unchanged.
        #expect(SmartShiftEnhanced.parameters(mode: .ratchet, autoDisengage: 12) == [2, 12, 0])
        #expect(SmartShiftEnhanced.parameters(mode: .freespin, autoDisengage: nil) == [1, 0, 0])
    }
}

struct HapticTests {
    @Test func waveformMaskIsBigEndianAtOffsetFour() throws {
        // Layout from Solaar PlayHapticWaveForm.validator_class.build. Constructed mask:
        // 0x08007FFF supports 0...14 and 27, not a captured capabilities response.
        let caps = try #require(Haptic.parseCapabilities([0xFF, 0xFF, 0xFF, 60, 0x08, 0x00, 0x7F, 0xFF, 0]))
        #expect(caps.supportedWaveforms == 0x08007FFF)
        #expect(caps.supports(0) && caps.supports(14) && caps.supports(27))
        #expect(!caps.supports(15) && !caps.supports(31) && !caps.supports(32) && !caps.supports(255))
        #expect(Haptic.parseCapabilities([0, 0, 0, 60, 0, 0, 0, 0])?.supports(0) == false)
        #expect(Haptic.parseCapabilities([0, 0, 0, 60, 0, 0, 0]) == nil)
    }
}

struct DPIListTests {
    @Test func steppedRange() throws {
        // getSensorDpiList as the MX Master 3S answers it: sensor 0, 200, step 50, 8000, end.
        let params: [UInt8] = [0x00, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let list = try #require(AdjustableDPI.parseResolutions(params))
        #expect(list.values.count == 157 && list.values.first == 200 && list.values.last == 8000)
        #expect(list.values.contains(1650) && !list.values.contains(1625))
        #expect(list.nearest(to: 1000) == 1000)
        #expect(list.nearest(to: 1630) == 1650)
        #expect(list.nearest(to: 1625) == 1600)  // tie: lower
        #expect(list.nearest(to: 50) == 200)
        #expect(list.nearest(to: 12000) == 8000)
    }

    @Test func discreteValues() throws {
        // 400, 800, 1600, 3200, end.
        let params: [UInt8] = [0x00, 0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0x0C, 0x80, 0x00, 0x00, 0, 0, 0, 0, 0]
        let list = try #require(AdjustableDPI.parseResolutions(params))
        #expect(list.values == [400, 800, 1600, 3200])
        #expect(list.nearest(to: 1000) == 800)
        #expect(list.nearest(to: 1300) == 1600)
    }

    @Test func rejectsEmptyOrDanglingStep() {
        #expect(AdjustableDPI.parseResolutions([0x00, 0x00, 0x00]) == nil)
        #expect(AdjustableDPI.parseResolutions([0x00, 0xE0, 0x32, 0x1F, 0x40, 0x00, 0x00]) == nil)  // no start
        #expect(AdjustableDPI.parseResolutions([0x00, 0x00, 0xC8, 0xE0, 0x32, 0x00, 0x00]) == nil)  // no end
    }
}
