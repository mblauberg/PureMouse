import HIDPPTesting
import Testing
@testable import PureMouseKit
@testable import puremouse

@MainActor
struct SessionCaptureTests {
    @Test func captureNeverDivertsOrListsPrimaryButtons() async throws {
        let fake = FakeDevice.mxMaster3S
        for cid: UInt16 in [0x50, 0x51] {
            let index = try #require(fake.controls.firstIndex { $0.cid == cid })
            fake.controls[index].info[4] = 0x20
        }
        var config = try SessionHarness.config(#"{"buttons":{"0x0050":"none"},"apps":{"com.example":{"buttons":{"0x51":"none"}}}}"#)
        // Bypass the decoder to prove the daemon's independent exclusion of bound controls.
        config.apps["com.example"]?.bindings[0x50] = .action(.none)
        let h = try await SessionHarness(fake, config: config, inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        h.session.beginCapture()
        await h.session.diversion.drain()
        for cid: UInt16 in [0x50, 0x51] {
            #expect(fake.control(cid)?.diverted == false)
            #expect(!h.session.status.controls.contains { $0.cid == cid })
            #expect(h.session.bound[cid] == nil)
            #expect(!h.session.isDivertable(cid))
            #expect(fake.controlWrites(cid: cid).isEmpty)
            #expect(!fake.requests(feature: 0x1B04, function: 2).contains { $0.params.prefix(2) == [0, UInt8(cid)] })
        }
        #expect(fake.control(0x53)?.diverted == true)
        h.session.endCapture()
        await h.session.diversion.drain()
        #expect(fake.controls.allSatisfy { !$0.diverted })
    }
}
