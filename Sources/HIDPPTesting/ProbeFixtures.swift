import Foundation

extension FakeDevice {
    public static var mxMaster3S: FakeDevice { fixture("mx-master-3s") }
    public static var m750: FakeDevice { fixture("m750") }

    private static func fixture(_ name: String) -> FakeDevice {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Test support runs from a checkout, just like tests of config.example.json.
        let url = root.appendingPathComponent("Tests/Fixtures/probe/\(name).txt")
        return probe(try! String(contentsOf: url, encoding: .utf8))
    }
}
