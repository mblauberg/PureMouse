import Foundation
import PureMouseKit
import Testing

struct PrimaryButtonConfigTests {
    @Test func primaryBindingsAreDroppedWithCanonicalWarnings() throws {
        for (key, cid): (String, UInt16) in [("0x0050", 0x50), ("0x51", 0x51)] {
            let config = try JSONDecoder().decode(Config.self,
                from: Data("{\"buttons\":{\"\(key)\":\"none\",\"back\":\"navigateBack\"}}".utf8))
            #expect(config.bindings[cid] == nil)
            #expect(config.buttons[key] == nil)
            #expect(config.bindings[0x53] != nil)
            #expect(config.warnings.contains(String(format: "buttons.0x%04x: the left and right buttons always click; ignored", cid)))
        }
    }

    @Test func appPrimaryBindingsAreDroppedWithScopedWarnings() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"apps":{"com.example.app":{"buttons":{"0x0051":"none"}}}}"#.utf8))
        #expect(config.apps["com.example.app"]?.bindings[0x51] == nil)
        #expect(config.apps["com.example.app"]?.buttons.contains(0x51) == false)
        #expect(config.warnings.contains("apps.com.example.app.buttons.0x0051: the left and right buttons always click; ignored"))
    }
}
