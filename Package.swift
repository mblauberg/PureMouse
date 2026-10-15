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
        // The daemon: config, gesture recognition, actions, reconnect handling.
        .executableTarget(
            name: "puremouse",
            dependencies: ["HIDPP", "PureMouseKit"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // The menu bar app: status menu and Settings window. Edits the config; never touches HID.
        .executableTarget(
            name: "PureMouseMenu",
            dependencies: ["PureMouseKit"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(name: "HIDPPTests", dependencies: ["HIDPP"]),
        .testTarget(name: "PureMouseTests", dependencies: ["puremouse"]),
        .testTarget(name: "PureMouseKitTests", dependencies: ["PureMouseKit"]),
        .testTarget(name: "PureMouseMenuTests", dependencies: ["PureMouseMenu"]),
    ]
)
