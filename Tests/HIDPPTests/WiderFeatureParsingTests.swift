import Testing
@testable import HIDPP

/// Layouts follow Solaar's `LowresMode`, `ExtendedAdjustableDpi` and `decipher_battery_voltage`
/// and the Linux driver's 0x1001 mapping; no raw capture of these three features is public, so
/// every byte below is built from those layouts (the one real 0x1001 sample is OpenLogi's G915).
struct LowResWheelEventTests {
    @Test func notchesAreSignedAndPositiveIsUp() {
        #expect(LowResWheel.parse(function: 0, params: [0x01]) == .scroll(notches: 1))
        #expect(LowResWheel.parse(function: 0, params: [0x03, 0x00]) == .scroll(notches: 3))
        #expect(LowResWheel.parse(function: 0, params: [0xFF]) == .scroll(notches: -1))
        #expect(LowResWheel.parse(function: 0, params: [0x80]) == .scroll(notches: -128))
    }

    @Test func aZeroOrEmptyOrOtherEventIsNotAScroll() {
        #expect(LowResWheel.parse(function: 0, params: [0x00]) == nil)
        #expect(LowResWheel.parse(function: 0, params: []) == nil)
        #expect(LowResWheel.parse(function: 1, params: [0x01]) == nil)
    }
}

struct ExtendedDPITests {
    @Test func capabilityBitsAreSeparateYAndLiftOff() throws {
        #expect(ExtendedDPI.parseCapabilities([0, 0, 0x03]) == .init(separateY: true, liftOffDistance: true))
        #expect(ExtendedDPI.parseCapabilities([0, 0, 0x01]) == .init(separateY: true, liftOffDistance: false))
        #expect(ExtendedDPI.parseCapabilities([0, 0, 0x02]) == .init(separateY: false, liftOffDistance: true))
        #expect(ExtendedDPI.parseCapabilities([0, 0]) == nil)
    }

    @Test func listSkipsThreeHeaderBytesAndReadsRangesAsIn2201() throws {
        // 100, step 50, 25600, terminator.
        let range = try #require(ExtendedDPI.parseResolutions([0, 0, 0, 0x00, 0x64, 0xE0, 0x32, 0x64, 0x00, 0, 0]))
        #expect(range.values.first == 100 && range.values.last == 25600 && range.values.count == 511)
        #expect(range.nearest(to: 801) == 800)
        let discrete = try #require(ExtendedDPI.parseResolutions([0, 1, 0, 0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0, 0]))
        #expect(discrete.values == [400, 800, 1600])
    }

    @Test func aListWithoutItsTerminatorOrWithABadStepIsRefused() {
        #expect(ExtendedDPI.parseResolutions([0, 0, 0, 0x00, 0x64, 0xE0, 0x32, 0x64, 0x00]) == nil)
        #expect(ExtendedDPI.parseResolutions([0, 0, 0, 0, 0]) == nil)
        #expect(ExtendedDPI.parseResolutions([0, 0, 0, 0xE0, 0x32, 0, 0]) == nil)
    }

    @Test func readingTakesTheDefaultWhenTheCurrentValueIsZero() throws {
        let superstrike: [UInt8] = [0, 0x03, 0x20, 0x03, 0x20, 0x03, 0x20, 0x03, 0x20, 2]
        #expect(ExtendedDPI.parseReading(superstrike) == .init(x: 800, liftOffDistance: 2))
        #expect(ExtendedDPI.parseReading([0, 0, 0, 0x06, 0x40, 0, 0, 0, 0, 1]) == .init(x: 1600, liftOffDistance: 1))
        #expect(ExtendedDPI.parseReading([0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == nil)
        #expect(ExtendedDPI.parseReading([0, 0x03, 0x20]) == nil)
    }

    @Test func aWriteSetsBothAxesAndKeepsTheLiftOffDistanceOnlyWhereItExists() {
        let read = ExtendedDPI.Reading(x: 800, liftOffDistance: 2)
        let both = ExtendedDPI.Capabilities(separateY: true, liftOffDistance: true)
        #expect(ExtendedDPI.parameters(dpi: 1200, capabilities: both, keeping: read) == [0, 0x04, 0xB0, 0x04, 0xB0, 2])
        let one = ExtendedDPI.Capabilities(separateY: false, liftOffDistance: false)
        #expect(ExtendedDPI.parameters(dpi: 1200, capabilities: one, keeping: read) == [0, 0x04, 0xB0, 0, 0, 0])
    }
}

struct BatteryVoltageTests {
    @Test func theOnlyRealSampleIsAFullDischargingG915() throws {
        // OpenLogi g915-001: 0F F8 00, i.e. 4088 mV, flags 0.
        let state = try #require(BatteryVoltage.parseStatus([0x0F, 0xF8, 0x00]))
        #expect(state == UnifiedBattery.State(percent: nil, level: .full, charging: .discharging, externalPower: false))
    }

    @Test func bandsFollowThePointsWhereBothCurvesReadEightyThirtyAndTenPercent() throws {
        func level(_ millivolts: Int) -> UnifiedBattery.Level? {
            BatteryVoltage.parseStatus([UInt8(millivolts >> 8), UInt8(millivolts & 0xFF), 0])?.level
        }
        #expect(level(3989) == .full && level(3988) == .good)
        #expect(level(3751) == .good && level(3750) == .low)
        #expect(level(3671) == .low && level(3670) == .critical)
    }

    @Test func chargingFlagsFollowTheDriver() throws {
        func state(_ flags: UInt8) -> UnifiedBattery.State? { BatteryVoltage.parseStatus([0x0E, 0x74, flags]) }
        #expect(state(0x80)?.charging == .charging && state(0x80)?.externalPower == true)
        #expect(state(0x90)?.charging == .chargingSlowly)
        #expect(state(0x81) == UnifiedBattery.State(percent: nil, level: .full, charging: .complete, externalPower: true))
        #expect(state(0x82)?.charging == nil && state(0x82)?.externalPower == true)
        #expect(state(0x20)?.level == .critical && state(0x20)?.charging == .discharging)
    }

    @Test func onlyTheFunctionZeroBroadcastAndFullReportsParse() {
        #expect(BatteryVoltage.parse(function: 0, params: [0x0F, 0xF8, 0x00]) != nil)
        #expect(BatteryVoltage.parse(function: 1, params: [0x0F, 0xF8, 0x00]) == nil)
        #expect(BatteryVoltage.parseStatus([0x0F, 0xF8]) == nil)
    }
}
