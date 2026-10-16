import Foundation
import Testing
@testable import puremouse
import PureMouseKit

@Suite struct ThumbStepperTests {
    let t0 = ContinuousClock.now

    @Test func carriesTheRemainder() {
        var s = ThumbStepper(threshold: 20)
        #expect(s.add(15, at: t0) == 0)
        #expect(s.add(10, at: t0) == 1)   // 25: one step, 5 left
        #expect(s.add(15, at: t0) == 1)   // 20
        #expect(s.add(-30, at: t0) == -1) // reversing drops the remainder first
    }

    @Test func fastSpinsGiveSeveralStepsUpToTheCap() {
        var s = ThumbStepper(threshold: 10)
        #expect(s.add(35, at: t0) == 3)
        #expect(s.add(5, at: t0) == 1)    // the 5 carried over
        #expect(s.add(200, at: t0) == 4)  // capped, and the excess dropped
        #expect(s.add(5, at: t0) == 0)
    }

    @Test func resetDropsTheRemainder() {
        var s = ThumbStepper(threshold: 10)
        #expect(s.add(9, at: t0) == 0)
        s.reset()
        #expect(s.add(9, at: t0) == 0)
    }

    @Test func animatedPacingTakesOneStepAndDiscardsMovementMeanwhile() {
        var s = ThumbStepper(threshold: 10, pacing: .init(interval: .milliseconds(300), discards: true))
        #expect(s.add(50, at: t0) == 1)
        #expect(s.add(50, at: t0 + .milliseconds(100)) == 0)
        #expect(s.add(5, at: t0 + .milliseconds(350)) == 0)  // fresh travel needed
        #expect(s.add(5, at: t0 + .milliseconds(360)) == 1)
    }

    @Test func shortcutPacingKeepsOneStepForLater() {
        var s = ThumbStepper(threshold: 10, pacing: .init(interval: .milliseconds(50)))
        #expect(s.add(45, at: t0) == 1)                          // one at a time
        #expect(s.add(45, at: t0 + .milliseconds(20)) == 0)      // held, capped at one step
        #expect(s.add(1, at: t0 + .milliseconds(60)) == 1)
        #expect(s.add(1, at: t0 + .milliseconds(120)) == 0)      // nothing more was kept
    }

    @Test func thresholdIsInNativeSteps() {
        // MX Master 3S: 18 native steps and 120 diverted units per turn.
        #expect(ThumbStepper.threshold(step: 3, native: 18, diverted: 120) == 20)
        #expect(ThumbStepper.threshold(step: 1, native: 18, diverted: 120) == 7)
        #expect(ThumbStepper.threshold(step: 1, native: 0, diverted: 0) == 1)
    }

    @Test func pacingFollowsTheActions() {
        #expect(ThumbStepper.pacing(left: .volumeDown, right: .volumeUp) == .init())
        #expect(ThumbStepper.pacing(left: .previousTab, right: .nextTab) == .init(interval: .milliseconds(50)))
        #expect(ThumbStepper.pacing(left: .zoomOut, right: .zoomIn) == .init(interval: .milliseconds(40)))
        #expect(ThumbStepper.pacing(left: .spaceLeft, right: .spaceRight) == .init(interval: .milliseconds(300), discards: true))
        #expect(ThumbStepper.pacing(left: .none, right: .missionControl).discards)
        #expect(ThumbStepper.pacing(left: .zoomOut, right: .nextTab).interval == .milliseconds(50))
    }
}

@Suite struct HeldButtonsTests {
    final class Posts { var log: [(UInt16, Bool)] = [] }

    func held(_ posts: Posts) -> HeldButtons {
        HeldButtons { cid, down in
            guard NativeButton.number(for: cid) != nil else { return false }
            posts.log.append((cid, down))
            return true
        }
    }

    @Test func dropReleasesANativeClickWhoseReleaseNeverCame() {
        // Middle bound only in another app, held, then the mouse turned off: link down drops it.
        let posts = Posts()
        var h = held(posts)
        _ = h.update([0x52])
        h.clickNatively(0x52)
        h.drop()
        #expect(posts.log.map(\.1) == [true, false] && h.native.isEmpty && h.pressed.isEmpty)
        // A release reported after reconnecting posts nothing more.
        let late = h.release(0x52)
        #expect(late == nil && posts.log.count == 2)
        let after = h.update([])
        #expect(after.released.isEmpty)
    }

    func gesture(click: String) throws -> Config.Binding.Gesture {
        try JSONDecoder().decode(Config.Binding.Gesture.self, from: Data(#"{"click": "\#(click)"}"#.utf8))
    }

    @Test func dropForgetsTheGesture() throws {
        var h = held(Posts())
        let gesture = try gesture(click: "missionControl")
        let first = h.holdGesture(0xC3, gesture), second = h.holdGesture(0xC4, gesture)
        #expect(first && !second)
        h.drop()
        let released = h.release(0xC3)
        #expect(h.gesture == nil && released == nil)
    }

    @Test func releaseEndsTheHoldItStarted() throws {
        let posts = Posts()
        var h = held(posts)
        h.clickNatively(0x53)
        h.clickNatively(0xC4)  // no click to post
        #expect(h.native == [0x53])
        let native = h.release(0x53)
        #expect(native == nil && posts.log.map(\.1) == [true, false])
        let holding = h.holdGesture(0xC3, try gesture(click: "launchpad"))
        let ended = h.release(0xC3)
        #expect(holding && ended?.click == .launchpad && h.gesture == nil)
    }
}

@Suite struct ForegroundAppTests {
    @Test func appBundleIsTheInnermostApp() {
        #expect(BundleIDCache.appBundle(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari")
                == "/Applications/Safari.app")
        #expect(BundleIDCache.appBundle(forExecutable:
            "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
            == "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app")
        #expect(BundleIDCache.appBundle(forExecutable: "/usr/bin/ssh") == nil)
    }

    @Test func cachesByPathIncludingMisses() {
        var cache = BundleIDCache()
        var reads = 0
        let read: (String) -> String? = { reads += 1; return $0.hasSuffix("Safari.app") ? "com.apple.Safari" : nil }
        #expect(cache.bundleID(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari", read: read) == "com.apple.Safari")
        #expect(cache.bundleID(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari", read: read) == "com.apple.Safari")
        #expect(cache.bundleID(forExecutable: "/usr/bin/ssh", read: read) == nil)
        #expect(cache.bundleID(forExecutable: "/usr/bin/ssh", read: read) == nil)
        #expect(reads == 1)  // ssh has no bundle to read
    }

    @Test func cacheIsBounded() {
        var cache = BundleIDCache()
        var reads = 0
        let read: (String) -> String? = { reads += 1; return $0 }
        for i in 0...BundleIDCache.capacity {
            _ = cache.bundleID(forExecutable: "/A\(i).app/x", read: read)
        }
        _ = cache.bundleID(forExecutable: "/A0.app/x", read: read)  // evicted when the cache filled
        #expect(reads == BundleIDCache.capacity + 2)
    }

    @Test func readsTheBundleIDOfARealApp() {
        #expect(BundleIDCache.readBundleID(appBundle: "/System/Applications/Calculator.app") == "com.apple.calculator")
    }

    @Test func symbolicHotKeys() {
        // ctrl+left as stored for "Move left a space": control plus the function-key flag.
        let left = SymbolicHotKey.keystroke(character: 0xFFFF, keyCode: 123, modifiers: 0x840000)
        #expect(left == Keystroke(key: 123, modifiers: [.maskControl, .maskSecondaryFn]))
        #expect(SymbolicHotKey.keystroke(character: 0xFFFF, keyCode: 0xFFFF, modifiers: 0) == nil)  // cleared
        #expect(SymbolicHotKey.keystroke(character: 0xFFFF, keyCode: 0, modifiers: 0) == nil)       // never set
        #expect(SymbolicHotKey.keystroke(character: 97, keyCode: 0, modifiers: 0x100000) == Keystroke(key: 0, modifiers: .maskCommand))
    }
}
