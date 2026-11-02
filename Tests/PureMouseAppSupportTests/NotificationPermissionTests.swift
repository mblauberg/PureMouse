import Foundation
import Testing
@testable import PureMouseAppSupport

@Suite struct NotificationPermissionTests {
    let suite = "PureMouseAppSupportTests-\(UUID().uuidString)"

    @Test func aDenialTheMenuRecordsIsWhatTheHelperReads() throws {
        let menu = try #require(UserDefaults(suiteName: suite))
        defer { menu.removePersistentDomain(forName: suite) }
        #expect(!NotificationPermission.denied(in: menu))
        NotificationPermission.record(denied: true, in: menu)
        // The helper opens the same domain by name, as it opens the menu bar app's.
        #expect(NotificationPermission.denied(in: UserDefaults(suiteName: suite)))
        NotificationPermission.record(denied: false, in: menu)
        #expect(!NotificationPermission.denied(in: UserDefaults(suiteName: suite)))
        #expect(menu.object(forKey: NotificationPermission.deniedKey) == nil)
    }

    @Test func noDomainReadsAsNotDenied() {
        #expect(!NotificationPermission.denied(in: nil))
    }

    @Test func permissionIsAskedForOnlyWhenTheSwitchTurnsOn() {
        #expect(NotificationPermission.shouldRequest(wasOn: false, isOn: true))
        #expect(!NotificationPermission.shouldRequest(wasOn: true, isOn: true))
        #expect(!NotificationPermission.shouldRequest(wasOn: true, isOn: false))
        #expect(!NotificationPermission.shouldRequest(wasOn: false, isOn: false))
    }
}
