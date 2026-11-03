import AppKit
import Testing
@testable import PureMouseSettings

// The Settings app's menu bar: About leads the app menu and shows the About tab; Help opens the
// troubleshooting page.

@MainActor
@Suite struct MainMenuTests {
    @MainActor
    private final class Spy {
        var aboutCount = 0
        var opened: [URL] = []
        var transfers: [String] = []
        lazy var actions = MainMenu.Actions(showAbout: { self.aboutCount += 1 }, open: { self.opened.append($0) },
                                            exportSettings: { self.transfers.append("export") },
                                            importSettings: { self.transfers.append("import") })
    }

    private func menu(_ spy: Spy) -> NSMenu {
        _ = NSApplication.shared
        return MainMenu.make(actions: spy.actions)
    }

    private func choose(_ item: NSMenuItem) {
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
    }

    @Test func theAppMenuStartsWithAbout() throws {
        let spy = Spy()
        let app = try #require(menu(spy).items.first?.submenu)
        let about = try #require(app.items.first)
        #expect(about.title == "About PureMouse")
        choose(about)
        #expect(spy.aboutCount == 1)
        #expect(spy.opened.isEmpty)
    }

    @Test func theHelpItemOpensTheTroubleshootingPage() throws {
        let spy = Spy()
        let help = try #require(menu(spy).items.first { $0.submenu?.title == "Help" }?.submenu)
        let item = try #require(help.items.first)
        #expect(item.title == "PureMouse Help")
        #expect(NSApp.helpMenu === help)
        choose(item)
        #expect(spy.opened == [URL(string: "https://github.com/mblauberg/PureMouse/blob/main/docs/troubleshooting.md")!])
        #expect(spy.aboutCount == 0)
    }

    @Test func theFileMenuHasExportAndImportSettings() throws {
        let spy = Spy()
        let file = try #require(menu(spy).items.first { $0.submenu?.title == "File" }?.submenu)
        #expect(file.items.map(\.title) == ["Export Settings…", "Import Settings…"])
        file.items.forEach(choose)
        #expect(spy.transfers == ["export", "import"])
        #expect(spy.aboutCount == 0 && spy.opened.isEmpty)
    }

    @Test func quitAndHideStayInTheAppMenu() throws {
        let app = try #require(menu(Spy()).items.first?.submenu)
        #expect(app.items.map(\.title) == ["About PureMouse", "", "Hide PureMouse", "", "Quit Settings"])
    }
}
