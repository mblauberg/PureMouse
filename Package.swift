// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PureMouse",
    platforms: [.macOS(.v14)],
    targets: [
        // HID++ 2.0 protocol: transport, framing, typed feature wrappers. No policy.
        .target(name: "HIDPP"),
        // Shared by the daemon and the menu bar app: config model and the status/control channel.
        .target(name: "PureMouseKit"),
        // The menu side's logic, shared by the menu bar app and the Settings helper: config editing,
        // the config and daemon files, select by pressing. No AppKit or SwiftUI.
        .target(
            name: "PureMouseAppSupport",
            dependencies: ["PureMouseKit"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The daemon: config, gesture recognition, actions, reconnect handling.
        .executableTarget(
            name: "puremouse",
            dependencies: ["HIDPP", "PureMouseKit"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The Settings window and its SwiftUI panes, over `AppModel`. Linked by the Settings helper
        // only: the resident menu bar app links no SwiftUI (docs/adr/0009-settings-helper-app.md).
        .target(
            name: "PureMouseSettingsUI",
            dependencies: ["PureMouseKit", "PureMouseAppSupport"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The menu bar app: status item and menu; opens the Settings helper. Edits the config; never
        // touches HID.
        .executableTarget(
            name: "PureMouseMenu",
            dependencies: ["PureMouseKit", "PureMouseAppSupport"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The Settings helper app (`PureMouse Settings.app`), started on demand by the menu bar app.
        .executableTarget(
            name: "PureMouseSettings",
            dependencies: ["PureMouseKit", "PureMouseAppSupport", "PureMouseSettingsUI"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .target(name: "HIDPPTesting", dependencies: ["HIDPP"]),
        .testTarget(name: "HIDPPTests", dependencies: ["HIDPP", "HIDPPTesting"]),
        .testTarget(name: "PureMouseTests", dependencies: ["puremouse", "HIDPPTesting"]),
        .testTarget(name: "PureMouseKitTests", dependencies: ["PureMouseKit"]),
        .testTarget(name: "PureMouseMenuTests", dependencies: ["PureMouseMenu"]),
        .testTarget(
            name: "PureMouseSettingsTests",
            dependencies: ["PureMouseSettingsUI", "PureMouseAppSupport"]
        ),
        .testTarget(
            name: "PureMouseAppSupportTests",
            dependencies: ["PureMouseAppSupport", "ConfigWriterProbe"],
            exclude: ["Probe"]
        ),
        // A second config and control writer for the two-process lock test. Test-only: no product
        // and not in the app bundle.
        .executableTarget(
            name: "ConfigWriterProbe",
            dependencies: ["PureMouseAppSupport", "PureMouseKit"],
            path: "Tests/PureMouseAppSupportTests/Probe"
        ),
    ]
)
