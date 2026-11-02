import Foundation
import Testing
@testable import PureMouseAppSupport

@Suite struct SettingsLookupTests {
    // `URL(filePath:)` infers a directory from the path alone; `fileURLWithPath:` asks the disk, so on a Mac
    // with PureMouse installed the expected bundles gained a trailing slash the lookup's do not.
    let menuApp = URL(filePath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")
    let menuBinary = URL(filePath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app/Contents/MacOS/PureMouseMenu")
    let nested = URL(filePath: "/Applications/PureMouse.app/Contents/Helpers/PureMouse Settings.app")
    // `swift build`: no bundle, so the "bundle" is the binary's directory.
    let buildDirectory = URL(filePath: "/src/PureMouse/.build/debug")
    let devMenu = URL(filePath: "/src/PureMouse/.build/debug/PureMouseMenu")
    let devHelper = URL(filePath: "/src/PureMouse/.build/debug/PureMouseSettings")

    func find(_ environment: [String: String] = [:], bundle: URL, executable: URL,
              existing: [URL]) -> Result<SettingsLookup.Helper, SettingsLookup.Failure> {
        SettingsLookup.find(environment: environment, bundle: bundle, executable: executable,
                            exists: { existing.map(\.path).contains($0.path) })
    }

    @Test func theInstalledMenuOpensTheHelperNestedInPureMouseApp() {
        #expect(find(bundle: menuApp, executable: menuBinary, existing: [nested]) == .success(.app(nested)))
    }

    @Test func theNestedAppWinsOverASiblingBinary() {
        let sibling = URL(filePath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app/Contents/MacOS/PureMouseSettings")
        #expect(find(bundle: menuApp, executable: menuBinary, existing: [nested, sibling]) == .success(.app(nested)))
    }

    @Test func aBareDevelopmentRunStartsTheSiblingBinary() {
        #expect(find(bundle: buildDirectory, executable: devMenu, existing: [devHelper]) == .success(.binary(devHelper)))
    }

    @Test func theOverrideWinsAndMayNameAnAppOrABinary() {
        let app = URL(filePath: "/tmp/build/PureMouse Settings.app")
        let binary = URL(filePath: "/tmp/build/PureMouseSettings")
        #expect(find(["PUREMOUSE_SETTINGS": app.path], bundle: menuApp, executable: menuBinary, existing: [nested, app])
            == .success(.app(app)))
        #expect(find(["PUREMOUSE_SETTINGS": binary.path], bundle: buildDirectory, executable: devMenu,
                     existing: [devHelper, binary]) == .success(.binary(binary)))
    }

    @Test func aMissingOverrideIsAnErrorNamingIt() {
        let result = find(["PUREMOUSE_SETTINGS": "/tmp/nowhere"], bundle: menuApp, executable: menuBinary, existing: [nested])
        #expect(result == .failure(.overrideMissing("/tmp/nowhere")))
        #expect(SettingsLookup.Failure.overrideMissing("/tmp/nowhere").description.contains("/tmp/nowhere"))
    }

    @Test func nothingFoundIsAnErrorNamingBothPlacesLooked() {
        let result = find(bundle: buildDirectory, executable: devMenu, existing: [])
        guard case .failure(let failure) = result else { Issue.record("found \(result)"); return }
        #expect(failure.description.contains(devHelper.path))
        #expect(failure.description.contains(SettingsLookup.appName))
    }

    @Test func theHelperInheritsOnlyTheDevelopmentOverrides() {
        let environment = ["PUREMOUSE_CONFIG": "/tmp/fixture/config.json", "PUREMOUSE_DAEMON": "/tmp/stub",
                           "XPC_SERVICE_NAME": "io.github.mblauberg.puremouse.menu", "HOME": "/Users/someone",
                           "PUREMOUSEX": "1", "puremouse_config": "/tmp/other"]
        #expect(SettingsLookup.environment(from: environment)
            == ["PUREMOUSE_CONFIG": "/tmp/fixture/config.json", "PUREMOUSE_DAEMON": "/tmp/stub"])
    }
}
