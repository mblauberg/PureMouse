// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PureMouse",
    platforms: [.macOS(.v14)],
    targets: [
        // HID++ 2.0 protocol: transport, framing, typed feature wrappers. No policy.
        .target(name: "HIDPP"),
        // The daemon: config, gesture recognition, actions, reconnect handling.
        .executableTarget(
            name: "puremouse",
            dependencies: ["HIDPP"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(name: "HIDPPTests", dependencies: ["HIDPP"]),
        .testTarget(name: "PureMouseTests", dependencies: ["puremouse"]),
    ]
)
