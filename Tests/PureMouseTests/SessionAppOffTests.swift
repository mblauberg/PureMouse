import Foundation
import HIDPP
import HIDPPTesting
import PureMouseKit
import Testing
@testable import puremouse

@MainActor
@Suite struct SessionAppOffTests {
    static let appOffConfig = """
        {
          "buttons": {"back": "mute", "forward": "playPause", "gesture": {"click": "missionControl", "left": "spaceLeft"}},
          "thumbWheel": {"action": "volume"},
          "smoothScroll": {"speed": 2.0, "smoothingMs": 300},
          "apps": {
            "com.valvesoftware.dota2": {
              "enabled": false,
              "buttons": {"back": "nextTrack"},
              "thumbWheel": {"action": "tabs"},
              "smoothScroll": {"speed": 3.0}
            }
          }
        }
        """

    /// What would be posted to the system, in place of posting it: a test must never click for real.
    final class Posts {
        var native: [String] = []
        var middle: [Bool] = []
    }

    private func recording(_ h: SessionHarness) -> Posts {
        let posts = Posts()
        h.session.held = HeldButtons(post: { cid, down in
            posts.native.append("\(down ? "down" : "up") \(ControlNames.describe(cid))")
            return true
        }, postMiddle: { posts.middle.append($0); return true })
        return posts
    }

    @Test func whenFrontmostAppIsOffButtonsClickNativelyOrDoNothingAndPointerIsFree() async throws {
        var env = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        env.frontmostApp = { "com.valvesoftware.dota2" }
        env.appUnderPointer = { "com.valvesoftware.dota2" }
        let config = try SessionHarness.config(Self.appOffConfig)
        let h = try await SessionHarness(config: config, environment: env)
        defer { h.close() }
        try await h.session.apply()
        let posts = recording(h)

        // Back, Forward and the wheel press click as the mouse would: not mute, play/pause or the
        // app's own next track.
        for cid: UInt16 in [0x0053, 0x0056, 0x0052] {
            await h.press(cid)
            #expect(h.session.held.native == [cid])
            await h.release()
            #expect(h.session.held.native.isEmpty)
        }
        #expect(posts.native.count == 6)
        #expect(posts.native.filter { $0.hasPrefix("down") }.count == 3)
        #expect(posts.middle.isEmpty)

        // The gesture button does nothing, holds no gesture and does not hold the pointer.
        #expect(h.fake.control(0x00C3)?.diverted == true)
        let before = posts.native.count
        await h.press(0x00C3)
        #expect(h.session.held.gesture == nil)
        #expect(h.session.pointerFree.contains(0x00C3))
        #expect(h.fake.control(0x00C3)?.rawXY == false)
        await h.release()
        #expect(h.session.pointerFree.isEmpty)
        #expect(posts.native.count == before)
    }

    @Test func whenAppUnderPointerIsOffWheelPassesThroughNatively() async throws {
        var env = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        var currentApp: String? = "com.valvesoftware.dota2"
        env.frontmostApp = { currentApp }
        env.appUnderPointer = { currentApp }
        let config = try SessionHarness.config(Self.appOffConfig)
        let h = try await SessionHarness(config: config, environment: env)
        defer { h.close() }
        try await h.session.apply()

        // While over Dota 2:
        let offProfile = h.session.profileUnderPointer()
        #expect(offProfile.speed == 1.0)
        #expect(offProfile.horizontalSpeed == 1.0)
        #expect(offProfile.acceleration == 0.0)
        #expect(offProfile.smoothing == .zero)
        #expect(offProfile.shiftScrollsHorizontally == false)
        #expect(offProfile.invertVertical == false)
        #expect(offProfile.invertHorizontal == false)

        // While over another app (not off): uses configured global profile
        currentApp = "com.apple.Safari"
        let normalProfile = h.session.profileUnderPointer()
        #expect(normalProfile.speed == 2.0)
        #expect(normalProfile.smoothing == .milliseconds(300))
    }
    @Test func anotherAppKeepsTheGlobalBindingsAndGestureWhileOneIsOff() async throws {
        var env = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        env.frontmostApp = { "com.apple.Safari" }
        env.appUnderPointer = { "com.apple.Safari" }
        let config = try SessionHarness.config(Self.appOffConfig)
        let h = try await SessionHarness(config: config, environment: env)
        defer { h.close() }
        try await h.session.apply()

        // The gesture button is still a gesture here: held, and the pointer held still.
        _ = recording(h)
        await h.press(0x00C3)
        #expect(h.session.held.gesture != nil)
        #expect(!h.session.pointerFree.contains(0x00C3))
        await h.release()
        #expect(h.session.held.gesture == nil)
    }

    @Test func offScrollsAsTheMouseSendsItKeepingTheMiceOwnInvertBits() async throws {
        var env = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        env.appUnderPointer = { "COM.VALVESOFTWARE.DOTA2" }  // regardless of case
        let config = try SessionHarness.config("""
            {"scrollWheel": {"inverted": true}, "thumbWheel": {"inverted": true},
             "smoothScroll": {"speed": 2.0, "acceleration": 2.0, "smoothingMs": 300, "shiftScrollsHorizontally": true},
             "apps": {"com.valvesoftware.dota2": {"enabled": false}}}
            """)
        let h = try await SessionHarness(config: config, environment: env)
        defer { h.close() }
        let profile = h.session.profileUnderPointer()
        #expect(profile.speed == 1 && profile.horizontalSpeed == 1 && profile.acceleration == 0)
        #expect(profile.smoothing == .zero)
        #expect(!profile.shiftScrollsHorizontally)
        #expect(profile.invertVertical && profile.invertHorizontal)
    }

    @Test func withNoAppOffNoLookupIsMadeForButtonsOrScrolling() async throws {
        var env = SessionEnvironment(canPostEvents: true, configureRetryDelay: .milliseconds(1))
        var lookups = 0
        env.frontmostApp = { lookups += 1; return nil }
        env.appUnderPointer = { lookups += 1; return nil }
        let config = try SessionHarness.config(#"{"buttons": {"back": "mute"}, "apps": {"a.b": {"smoothScroll": {"speed": 2}}}}"#)
        let h = try await SessionHarness(config: config, environment: env)
        defer { h.close() }
        #expect(!h.session.hasDisabledApps)
        try await h.session.apply()
        await h.press(0x0053)
        await h.release()
        #expect(lookups == 0)
    }
}
