import HIDPPTesting
import Testing
@testable import puremouse

@MainActor
struct SessionCaptureTests {
    @Test func captureNeverDivertsOrListsPrimaryButtons() async throws {
        let fake = FakeDevice.mxMaster3S
        for cid: UInt16 in [0x50, 0x51] {
            let index = try #require(fake.controls.firstIndex { $0.cid == cid })
            fake.controls[index].info[4] = 0x20
        }
        let config = try SessionHarness.config(#"{"buttons":{"0x0050":"none"},"apps":{"com.example":{"buttons":{"0x51":"none"}}}}"#)
        let h = try await SessionHarness(fake, config: config, inheriting: .init(fresh: true))
        defer { h.close() }
        try await h.session.apply()
        h.session.beginCapture()
        await h.session.diversion.drain()
        for cid: UInt16 in [0x50, 0x51] {
            #expect(fake.controls.first { $0.cid == cid }?.diverted == false)
            #expect(!h.session.status.controls.contains { $0.cid == cid })
            #expect(h.session.bound[cid] == nil)
        }
        #expect(fake.controls.first { $0.cid == 0x53 }?.diverted == true)
        h.session.endCapture()
        await h.session.diversion.drain()
        #expect(fake.controls.allSatisfy { !$0.diverted })
    }
}
