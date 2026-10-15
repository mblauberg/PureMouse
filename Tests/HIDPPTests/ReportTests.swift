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

    @Test func matchesError10() {
        let req = Report(reportID: .short, deviceIndex: 0xFF, featureIndex: 0x80, function: 0, softwareID: 0, params: [0, 9, 0])
        let err = Report(bytes: [0x10, 0xFF, 0x8F, 0x80, 0x00, 0x03, 0x00])!
        #expect(err.error(for: req) == .protocol10(code: 3))
    }
}

@Suite struct FeatureParsingTests {
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
        #expect(UnifiedBattery.parseStatus([10, 0x03, 0x00, 0x00])?.level == .critical)  // lowest bit wins
    }

    @Test func rejectsOtherFunctionsAndShortOrBadReports() {
        #expect(UnifiedBattery.parse(function: 1, params: [0x2D, 0x04, 0x00, 0x00]) == nil)
        #expect(UnifiedBattery.parseStatus([0x2D, 0x04]) == nil)
        #expect(UnifiedBattery.parseStatus([200, 0x04, 0x00, 0x00]) == nil)
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
