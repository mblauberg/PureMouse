import Foundation
import IOKit.hidsystem
import Testing
@testable import puremouse
import PureMouseKit

// Media actions post their NX key codes, and a button bound to Middle Click holds the middle button
// down until it is let go, so a press can drag.

@MainActor @Test func mediaActionsPostTheirAuxKeys() {
    #expect(AuxKey.key(for: .playPause) == NX_KEYTYPE_PLAY)
    #expect(AuxKey.key(for: .nextTrack) == NX_KEYTYPE_FAST)
    #expect(AuxKey.key(for: .previousTrack) == NX_KEYTYPE_REWIND)
    #expect(AuxKey.key(for: .volumeUp) == NX_KEYTYPE_SOUND_UP)
    #expect(AuxKey.key(for: .volumeDown) == NX_KEYTYPE_SOUND_DOWN)
    #expect(AuxKey.key(for: .mute) == NX_KEYTYPE_MUTE)
    #expect(AuxKey.key(for: .brightnessUp) == NX_KEYTYPE_BRIGHTNESS_UP)
    #expect(AuxKey.key(for: .brightnessDown) == NX_KEYTYPE_BRIGHTNESS_DOWN)
    #expect(AuxKey.key(for: .middleClick) == nil)
    #expect(AuxKey.key(for: .missionControl) == nil)
}

@Suite struct MiddleClickHoldTests {
    final class Posts { var middle: [Bool] = []; var native: [(UInt16, Bool)] = [] }

    func held(_ posts: Posts) -> HeldButtons {
        HeldButtons(post: { cid, down in
            posts.native.append((cid, down))
            return true
        }, postMiddle: { down in
            posts.middle.append(down)
            return true
        })
    }

    @Test func middleClickIsHeldUntilRelease() {
        let posts = Posts()
        var h = held(posts)
        _ = h.update([0x52])
        h.pressMiddle(0x52)
        #expect(posts.middle == [true] && h.middle == [0x52])
        // Still held: no up yet.
        #expect(posts.middle == [true])
        let (_, released) = h.update([])
        #expect(released == [0x52])
        #expect(h.release(0x52) == nil)
        #expect(posts.middle == [true, false] && h.middle.isEmpty)
        // A second release posts nothing more.
        #expect(h.release(0x52) == nil && posts.middle == [true, false])
        #expect(posts.native.isEmpty)
    }

    @Test func overlappingMiddleHoldsReleaseOnlyAfterLastOwner() {
        let posts = Posts()
        var h = held(posts)
        h.pressMiddle(0x53)
        h.pressMiddle(0x53)
        h.pressMiddle(0x54)
        #expect(posts.middle == [true] && h.middle == [0x53, 0x54])
        _ = h.release(0x53)
        #expect(posts.middle == [true])
        _ = h.release(0x54)
        #expect(posts.middle == [true, false])
    }

    @Test func nativeWheelAndMiddleClickShareTheHold() {
        for nativeFirst in [true, false] {
            let posts = Posts()
            var h = held(posts)
            if nativeFirst {
                h.clickNatively(0x52)
                h.pressMiddle(0x53)
                _ = h.release(0x52)
                #expect(posts.native.map(\.1) == [true] && posts.middle.isEmpty)
                _ = h.release(0x53)
                #expect(posts.middle == [false])
            } else {
                h.pressMiddle(0x53)
                h.clickNatively(0x52)
                _ = h.release(0x53)
                #expect(posts.middle == [true] && posts.native.isEmpty)
                _ = h.release(0x52)
                #expect(posts.native.map(\.1) == [false])
            }
        }
    }

    @Test func duplicateNativePressDoesNotPostTwice() {
        let posts = Posts()
        var h = held(posts)
        h.clickNatively(0x52)
        h.clickNatively(0x52)
        _ = h.release(0x52)
        #expect(posts.native.map(\.1) == [true, false])
    }

    @Test func failedFirstMiddlePressDoesNotCreateAnOwner() {
        var attempts = 0
        var h = HeldButtons(postMiddle: { _ in attempts += 1; return false })
        h.pressMiddle(0x53)
        #expect(h.middle.isEmpty && attempts == 1)
        _ = h.release(0x53)
        #expect(attempts == 1)
    }

    @Test func dropReleasesOverlappingMiddleHoldsOnce() {
        let posts = Posts()
        var h = held(posts)
        h.clickNatively(0x52)
        h.pressMiddle(0x53)
        h.pressMiddle(0x54)
        h.drop()
        #expect(posts.native.map(\.1) == [true] && posts.middle == [false])
        #expect(h.native.isEmpty && h.middle.isEmpty)
    }

    @Test func dropReleasesAHeldMiddleClick() {
        let posts = Posts()
        var h = held(posts)
        _ = h.update([0x52])
        h.pressMiddle(0x52)
        h.drop()
        #expect(posts.middle == [true, false] && h.middle.isEmpty && h.pressed.isEmpty)
        // A release reported after the drop posts nothing more.
        #expect(h.release(0x52) == nil && posts.middle == [true, false])
    }
}
