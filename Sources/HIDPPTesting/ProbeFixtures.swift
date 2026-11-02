import Foundation

extension FakeDevice {
    /// OpenLogi's raw capture of a direct Bluetooth LE mouse (`mx-master-3s-001`).
    public static var mxMaster3S: FakeDevice { fixture("mx-master-3s") }
    /// OpenLogi's raw capture (`mx-master-4-001`), taken through a Bolt receiver.
    public static var mxMaster4: FakeDevice { fixture("mx-master-4") }
    /// OpenLogi's raw capture (`mx-ergo-001`): no 0x2201, a notched 0x2130 wheel, controls that
    /// can be diverted persistently.
    public static var mxErgo: FakeDevice { fixture("mx-ergo") }
    /// Built from Solaar's listing, not captured: 0x2201 and onboard profiles (0x8100), which
    /// read "On-Board" there. The fake keeps its own DPI on a write, as an onboard profile may.
    public static var g305: FakeDevice {
        let fake = fixture("g305")
        fake.ignoresDPIWrites = true
        return fake
    }
    /// Built from Solaar's listing, not captured: 0x2202 without 0x2201 or 0x1B04.
    public static var superstrike: FakeDevice { fixture("g-pro-x-2-superstrike") }
    /// adlyzi's dump from issue #1, taken while PureMouse had diverted 0x00FD; the fake starts
    /// with every control native.
    public static var m750: FakeDevice {
        let fake = fixture("m750")
        fake.resetReporting()
        return fake
    }

    private static func fixture(_ name: String) -> FakeDevice {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Test support runs from a checkout, just like tests of config.example.json.
        let url = root.appendingPathComponent("Tests/Fixtures/probe/\(name).txt")
        return probe(try! String(contentsOf: url, encoding: .utf8))
    }
}
