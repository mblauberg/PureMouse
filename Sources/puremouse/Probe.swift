import Foundation
import HIDPP

/// `puremouse probe`: read-only dump of every HID++ device and the state of the features PureMouse
/// uses. Sends only get-style requests, so it is safe to run alongside other HID++ software.
@MainActor
enum Probe {
    static func run(monitor: HIDMonitor) async {
        try? await Task.sleep(for: .milliseconds(300))  // let device matching settle
        if monitor.interfaces.isEmpty { print("No Logitech HID++ interfaces found.") }
        for interface in monitor.interfaces {
            print(String(format: "\n== %@ pid=0x%04x page=0x%04x transport=%@", interface.product,
                         interface.productID, interface.usagePage, interface.transport))
            let indices: [UInt8] = interface.isReceiver ? Array(1...6) : [directDeviceIndex]
            for index in indices {
                // Its own software IDs, so replies cannot be confused with the daemon's.
                let device = HIDPPDevice(interface: interface, index: index, softwareIDs: 0x2...0x7)
                defer { device.close() }
                guard let version = await device.protocolVersion() else {
                    if !interface.isReceiver { print("  no response") }
                    continue
                }
                print("\n-- index \(index): HID++ \(version.major).\(version.minor)")
                guard version.major >= 2 else { continue }
                await dump(device)
            }
        }
    }

    private static func dump(_ d: HIDPPDevice) async {
        if let name = try? await DeviceName.get(d) { print("  name: \(name)") }

        if let count = try? await d.call(0x0001, 0).first {
            var features: [String] = []
            for i in 1...count {
                if let r = try? await d.call(0x0001, 1, [i]), r.count >= 2 {
                    features.append(String(format: "%02x:%04x", i, UInt16(r[0]) << 8 | UInt16(r[1])))
                }
            }
            print("  features: " + features.joined(separator: " "))
        }

        if let count = try? await d.call(0x1B04, 0).first {
            print("  controls (0x1B04 getCidInfo / getCidReporting):")
            for i in 0..<count {
                guard let info = try? await d.call(0x1B04, 1, [i]), info.count >= 9 else { continue }
                let reporting = (try? await d.call(0x1B04, 2, [info[0], info[1]])) ?? []
                print("    cid=0x\(hex(info[0]))\(hex(info[1])) info=\(hex(info.prefix(9))) reporting=\(hex(reporting.prefix(6)))")
            }
        }

        await show(d, "smartshift 0x2110 get", 0x2110, 0)
        await show(d, "smartshift 0x2111 caps", 0x2111, 0)
        await show(d, "smartshift 0x2111 get", 0x2111, 1)
        await show(d, "dpi 0x2201 sensors", 0x2201, 0)
        await show(d, "dpi 0x2201 list", 0x2201, 1, [0])
        await show(d, "dpi 0x2201 get", 0x2201, 2, [0])
        await show(d, "hires 0x2121 caps", 0x2121, 0)
        await show(d, "hires 0x2121 mode", 0x2121, 1)
        await show(d, "thumb 0x2150 info", 0x2150, 0)
        await show(d, "thumb 0x2150 status", 0x2150, 1)
        await show(d, "battery 0x1004 status", 0x1004, 1)
    }

    private static func show(_ d: HIDPPDevice, _ label: String, _ feature: UInt16, _ fn: UInt8,
                             _ params: [UInt8] = []) async {
        do {
            print("  \(label): \(hex(try await d.call(feature, fn, params)))")
        } catch {
            print("  \(label): \(error)")
        }
    }

    private static func hex(_ b: UInt8) -> String { String(format: "%02x", b) }
    private static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { hex($0) }.joined(separator: " ")
    }
}
