import Foundation
import PureMouseKit
import Testing

struct PrimaryButtonConfigTests {
    @Test func primaryBindingsAreDroppedWithWarningsKeyedAsSpelled() throws {
        for (key, cid): (String, UInt16) in [("0x0050", 0x50), ("0x51", 0x51)] {
            let config = try JSONDecoder().decode(Config.self,
                from: Data("{\"buttons\":{\"\(key)\":\"none\",\"back\":\"navigateBack\"}}".utf8))
            #expect(config.bindings[cid] == nil)
            #expect(config.buttons[key] == nil)
            #expect(config.bindings[0x53] != nil)
            #expect(config.warnings == ["buttons.\(key): the left and right buttons always click; ignored"])
        }
    }

    @Test func appPrimaryBindingsAreDroppedWithScopedWarnings() throws {
        let config = try JSONDecoder().decode(Config.self,
            from: Data(#"{"apps":{"com.Example.app":{"buttons":{"0x51":"none","back":"none"}}}}"#.utf8))
        let app = try #require(config.apps["com.example.app"])
        #expect(app.bindings[0x51] == nil)
        #expect(!app.buttons.contains(0x51))
        #expect(app.buttons == [0x53])
        #expect(config.warnings == ["apps.com.Example.app.buttons.0x51: the left and right buttons always click; ignored"])
    }
}
