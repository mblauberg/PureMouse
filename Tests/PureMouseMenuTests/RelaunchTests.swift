import Foundation
import Testing
@testable import PureMouseMenu

@MainActor @Test func relaunchWaitsOutLaunchdsRespawnThrottle() {
    let now = ProcessInfo.processInfo.systemUptime
    #expect(Relaunch.delay(launchedAt: now) > 10)
    #expect(Relaunch.delay(launchedAt: now - 60) == 0.5)
}
