import Foundation

extension FakeDevice {
    public static var mxMaster3S: FakeDevice { fixture("mx-master-3s") }
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
