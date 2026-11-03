import Foundation
import PureMouseKit
import Testing
@testable import PureMouseAppSupport

// "Use PureMouse in this app" (`apps.<id>.enabled`): absent means on; off writes `false`, on removes
// the key; visiting an app's page writes nothing; the list row reads "Off"; turning an app back on
// restores what it had, because nothing was deleted. Kit's decoder is the oracle.

private func tree(_ json: String) throws -> ConfigTree { try ConfigTree(data: Data(json.utf8)) }
private func decode(_ config: ConfigTree) throws -> Config { try JSONDecoder().decode(Config.self, from: config.data()) }

@Suite struct AppEnabledTests {
    @Test func offWritesFalseAndOnRemovesTheKeyAndAnEmptyEntry() throws {
        var config = try tree("{}")
        config.setAppEnabled("com.valvesoftware.dota2", false)
        #expect(config.bool(["apps", "com.valvesoftware.dota2", "enabled"]) == false)
        #expect(!config.isAppEnabled("com.valvesoftware.dota2"))
        #expect(try decode(config).settings(forApp: "com.valvesoftware.dota2")?.enabled == false)

        config.setAppEnabled("com.valvesoftware.dota2", true)
        #expect(!config.contains(["apps"]))
        #expect(config.isAppEnabled("com.valvesoftware.dota2"))
    }

    @Test func turningAnAppBackOnKeepsItsOwnSettingsAndUnknownKeys() throws {
        let json = #"{"apps": {"a.b": {"buttons": {"back": "mute"}, "smoothScroll": {"speed": 2}, "future": {"x": 1}}}}"#
        var config = try tree(json)
        config.setAppEnabled("a.b", false)
        #expect(config.string(["apps", "a.b", "buttons", "back"]) == "mute")
        #expect(config.double(["apps", "a.b", "smoothScroll", "speed"]) == 2)
        #expect(config.contains(["apps", "a.b", "future", "x"]))
        config.setAppEnabled("a.b", true)
        #expect(config.data() == (try tree(json)).data())
    }

    @Test func visitingAnAppsPageWritesNothing() throws {
        // The switch only reads; turning an app on that is on changes no key.
        let config = try tree(#"{"apps": {"a.b": {"buttons": {"back": "mute"}}}}"#)
        var visited = config
        _ = visited.isAppEnabled("a.b")
        _ = visited.appSummary("a.b")
        visited.setAppEnabled("a.b", true)
        #expect(config.changes(to: visited).isEmpty)
        #expect(visited.data() == config.data())
        // An app added from the list and not yet changed is not in the file at all.
        var added = try tree("{}")
        added.setAppEnabled("c.d", true)
        #expect(added.data() == ConfigTree().data())
    }

    @Test func bundleIDsMatchRegardlessOfCase() throws {
        let config = try tree(#"{"apps": {"com.Valve.Dota2": {"enabled": false}}}"#)
        #expect(!config.isAppEnabled("com.valve.dota2"))
        #expect(config.isAppEnabled("com.other"))
    }

    @Test func switchingAnAppUsesTheKeyAlreadyInTheFileWhateverItsCase() throws {
        var config = try tree(#"{"apps": {"com.Valve.Dota2": {"buttons": {"back": "mute"}}}}"#)
        config.setAppEnabled("com.valve.dota2", false)
        #expect(config.appIDs == ["com.Valve.Dota2"])
        #expect(config.bool(["apps", "com.Valve.Dota2", "enabled"]) == false)
        #expect(!config.isAppEnabled("COM.VALVE.DOTA2"))
        config.setAppEnabled("com.valve.dota2", true)
        #expect(config.appIDs == ["com.Valve.Dota2"])
        #expect(!config.contains(["apps", "com.Valve.Dota2", "enabled"]))
        #expect(config.string(["apps", "com.Valve.Dota2", "buttons", "back"]) == "mute")
    }

    @Test func theListRowReadsOffInsteadOfItsAreas() throws {
        let config = try tree(#"{"apps": {"a.b": {"enabled": false, "buttons": {"back": "mute"}}, "c.d": {"buttons": {"back": "mute"}, "enabled": true}}}"#)
        #expect(config.appSummary("a.b") == "Off")
        #expect(config.appSummary("c.d") == "Buttons")
        // Unchanged until an app is off.
        #expect(try tree(#"{"apps": {"e.f": {}}}"#).appSummary("e.f") == AppList.noCustomSettings)
    }

    @Test func offBeatsEveryScopeInTheDecodedConfig() throws {
        let json = #"""
            {"buttons": {"back": "mute"},
             "devices": {"mb03400000000": {"buttons": {"back": "playPause"}}},
             "apps": {"a.b": {"enabled": false, "buttons": {"back": "nextTrack"}, "smoothScroll": {"speed": 3}}}}
            """#
        let off = try decode(tree(json))
        #expect(off.settings(forApp: "a.b")?.enabled == false)
        // Its own settings are still decoded: turning it on restores them.
        let on = try decode(tree(json.replacingOccurrences(of: #""enabled": false, "#, with: "")))
        #expect(on.settings(forApp: "a.b")?.enabled == true)
        #expect(on.settings(forApp: "a.b")?.bindings[0x0053] != nil)
        #expect(on.settings(forApp: "a.b")?.smoothScroll?.speed == 3)
        #expect(off.settings(forApp: "a.b")?.bindings[0x0053] != nil)
    }
}
