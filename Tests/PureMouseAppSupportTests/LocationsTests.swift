import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
private let menuApp = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")

@Test func locationsHonourTheDevelopmentOverrides() {
    let locations = Locations(environment: ["PUREMOUSE_CONFIG": "/tmp/fixture/config.json",
                                            "PUREMOUSE_DAEMON": "/tmp/fixture/stub-daemon",
                                            "PUREMOUSE_COMPANION_DIR": "/tmp/fixture/companion"],
                              home: home, bundle: menuApp, isExecutable: { _ in true })
    #expect(locations.config == URL(fileURLWithPath: "/tmp/fixture/config.json"))
    #expect(locations.daemon == URL(fileURLWithPath: "/tmp/fixture/stub-daemon"))
    #expect(locations.companion == URL(fileURLWithPath: "/tmp/fixture/companion", isDirectory: true))
    #expect(locations.status.path == "/tmp/fixture/companion/status.json")
    #expect(locations.control.path == "/tmp/fixture/companion/control.json")
    #expect(locations.daemonOverridden)
    // A stub daemon always shows the icon, as `Paths.showsInMenuBar` did.
    #expect(locations.showsInMenuBar)
}

@Test func locationsWithoutOverridesAreTheInstalledOnes() {
    var probed: URL?
    let locations = Locations(environment: [:], home: home, bundle: menuApp, isExecutable: { probed = $0; return true })
    #expect(locations.config.path == "/Users/someone/.config/puremouse/config.json")
    #expect(locations.log.path == "/Users/someone/Library/Logs/PureMouse.log")
    #expect(locations.daemon?.path == "/Applications/PureMouse.app/Contents/MacOS/puremouse")
    #expect(probed?.path == "/Applications/PureMouse.app/Contents/MacOS/puremouse")
    #expect(locations.companion.path == "/Users/someone/Library/Application Support/PureMouse")
    #expect(!locations.daemonOverridden)
    let bare = Locations(environment: [:], home: home, bundle: menuApp, isExecutable: { _ in false })
    #expect(bare.daemon == nil)
}

@Test func anEmptyCompanionOverrideIsUnsetAsInTheDaemon() {
    let locations = Locations(environment: ["PUREMOUSE_COMPANION_DIR": ""], home: home, bundle: menuApp)
    #expect(locations.companion.path == "/Users/someone/Library/Application Support/PureMouse")
}

@Test func theSettingsHelperFindsTheDaemonOfTheAppItIsNestedIn() {
    let helper = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Helpers/PureMouse Settings.app")
    var probed: URL?
    let locations = Locations(environment: [:], home: home, bundle: helper, isExecutable: { probed = $0; return true })
    #expect(locations.daemon?.path == "/Applications/PureMouse.app/Contents/MacOS/puremouse")
    #expect(probed?.path == "/Applications/PureMouse.app/Contents/MacOS/puremouse")
    // The nearest enclosing Contents, even under a folder of that name.
    let deep = URL(fileURLWithPath: "/Users/x/Contents/PureMouse.app/Contents/Helpers/PureMouse Settings.app")
    let nested = Locations(environment: [:], home: home, bundle: deep, isExecutable: { _ in true })
    #expect(nested.daemon?.path == "/Users/x/Contents/PureMouse.app/Contents/MacOS/puremouse")
    // A bare development binary's "bundle" is its directory: no app around it.
    let bare = Locations(environment: [:], home: home, bundle: URL(fileURLWithPath: "/src/PureMouse/.build/debug"),
                         isExecutable: { _ in true })
    #expect(bare.daemon == nil)
}

@Test func liveLocationsReadThisProcessesEnvironment() {
    let environment = ProcessInfo.processInfo.environment
    let expected = Locations(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser,
                             bundle: Bundle.main.bundleURL)
    #expect(Locations.live.config == expected.config)
    #expect(Locations.live.daemon == expected.daemon)
    #expect(Locations.live.companion == expected.companion)
    // The same directory as Kit's own `Companion.directory`, which the daemon uses.
    #expect(Locations.live.companion.standardizedFileURL.path == Companion.directory.standardizedFileURL.path)
}
