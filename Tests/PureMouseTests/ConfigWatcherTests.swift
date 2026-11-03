import Foundation
import HIDPPTesting
import Testing
@testable import puremouse

/// A scratch tree with a config path two levels down, so there is an ancestor to fall back on.
@MainActor
private final class WatchFixture {
    let root: URL
    let directory: URL
    let config: URL
    /// Whether the config file existed at each reload, since a reload with no file is no use.
    private var seen: [Bool] = []
    var reloads: Int { seen.count }
    var reloadsWithAFile: Int { seen.filter { $0 }.count }
    private var watcher: ConfigWatcher?

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PureMouseWatcherTests-\(UUID().uuidString)")
        directory = root.appending(path: "config/puremouse")
        config = directory.appending(path: "config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() {
        watcher = ConfigWatcher(url: config) { [weak self] in
            guard let self else { return }
            seen.append(FileManager.default.fileExists(atPath: config.path))
        }
        watcher?.start()
    }

    func writeConfig(_ text: String = "{}") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: config, atomically: true, encoding: .utf8)
    }

    /// Overwrites the config through its existing inode, as an editor that saves in place does:
    /// the directory sees nothing.
    func rewriteInPlace(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: config)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// A folder of its own under the root holding a config, for a symlink to point at.
    func target(_ name: String, config text: String = "{}") throws -> URL {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Makes the config folder a symlink to `folder`; with `replacing`, swaps it in over the
    /// existing link in one step, as `ln -sfh` or a dotfiles tool does.
    func link(to folder: URL, replacing: Bool = false) throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if !replacing {
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: folder)
            return
        }
        let temporary = parent.appending(path: "swap-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: folder)
        #expect(rename(temporary.path, directory.path) == 0)
    }

    /// A pause long enough for several debounce periods to have passed, for asserting that
    /// nothing more happens.
    func quiet() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite(.quietLog) struct ConfigWatcherTests {
    @Test func aSaveInPlaceReloadsOnce() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try fixture.writeConfig("{\"dpi\": 800}")
        try await eventually { fixture.reloads >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
    }

    @Test func deletingAndRecreatingTheDirectoryReloadsOnce() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try FileManager.default.removeItem(at: fixture.directory)
        // Past the debounce, so the deletion is seen on its own.
        try await fixture.quiet()
        try fixture.writeConfig("{\"dpi\": 800}")
        try await eventually { fixture.reloadsWithAFile >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
    }

    @Test func editsAfterTheDirectoryIsRecreatedStillReload() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try FileManager.default.removeItem(at: fixture.directory)
        try await fixture.quiet()
        try fixture.writeConfig()
        try await eventually { fixture.reloadsWithAFile >= 1 }
        try await fixture.quiet()
        try fixture.writeConfig("{\"dpi\": 1600}")
        try await eventually { fixture.reloadsWithAFile >= 2 }
    }

    @Test func startingWithTheDirectoryMissingReloadsWhenItAppears() async throws {
        let fixture = try WatchFixture()
        fixture.start()
        try fixture.writeConfig()
        try await eventually { fixture.reloads >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
        try fixture.writeConfig("{\"dpi\": 1600}")
        try await eventually { fixture.reloads >= 2 }
    }

    @Test func aDirectoryCreatedOneLevelAtATimeIsFound() async throws {
        let fixture = try WatchFixture()
        fixture.start()
        try FileManager.default.createDirectory(
            at: fixture.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await fixture.quiet()
        #expect(fixture.reloads == 0)
        try fixture.writeConfig()
        try await eventually { fixture.reloads >= 1 }
    }

    @Test func nothingFiresWhileTheDirectoryStaysAbsent() async throws {
        let fixture = try WatchFixture()
        fixture.start()
        // Unrelated changes beside where the folder would be.
        try "x".write(to: fixture.root.appending(path: "other.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try await fixture.quiet()
        #expect(fixture.reloads == 0)
    }

    @Test func aDeletedDirectoryDoesNotReloadUntilItReturns() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try FileManager.default.removeItem(at: fixture.directory)
        try await fixture.quiet()
        #expect(fixture.reloads == 0)
    }

    @Test func aWriteThatKeepsTheInodeReloadsOnce() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try fixture.rewriteInPlace("{\"dpi\": 800}")
        try await eventually { fixture.reloads >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
    }

    @Test func aWriteThatKeepsTheInodeStillReloadsAfterTheDirectoryIsRecreated() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        fixture.start()
        try FileManager.default.removeItem(at: fixture.directory)
        try await fixture.quiet()
        try fixture.writeConfig()
        try await eventually { fixture.reloadsWithAFile >= 1 }
        try await fixture.quiet()
        try fixture.rewriteInPlace("{\"dpi\": 1600}")
        try await eventually { fixture.reloadsWithAFile >= 2 }
    }

    @Test func swappingASymlinkedFolderForAnotherReloadsAndFollowsTheNewOne() async throws {
        let fixture = try WatchFixture()
        let first = try fixture.target("dotfiles-a")
        let second = try fixture.target("dotfiles-b")
        try fixture.link(to: first)
        fixture.start()
        try fixture.link(to: second, replacing: true)
        try await eventually { fixture.reloads >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
        // Edits in the new target apply; the old one no longer matters.
        try fixture.rewriteInPlace("{\"dpi\": 800}")
        try await eventually { fixture.reloads >= 2 }
        try "{}".write(to: first.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try await fixture.quiet()
        #expect(fixture.reloads == 2)
    }

    @Test func replacingTheTargetOfASymlinkedFolderIsFollowed() async throws {
        let fixture = try WatchFixture()
        let target = try fixture.target("dotfiles")
        try fixture.link(to: target)
        fixture.start()
        try FileManager.default.removeItem(at: target)
        try await fixture.quiet()
        #expect(fixture.reloads == 0)
        _ = try fixture.target("dotfiles", config: "{\"dpi\": 800}")
        try await eventually { fixture.reloadsWithAFile >= 1 }
        try await fixture.quiet()
        let reloads = fixture.reloads
        try fixture.rewriteInPlace("{\"dpi\": 1600}")
        try await eventually { fixture.reloads > reloads }
    }

    @Test func unrelatedChangesBesideASymlinkedFolderDoNotReload() async throws {
        let fixture = try WatchFixture()
        try fixture.link(to: try fixture.target("dotfiles"))
        fixture.start()
        let beside = fixture.directory.deletingLastPathComponent()
        try "x".write(to: beside.appending(path: "other.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: beside.appending(path: "another"), withIntermediateDirectories: true)
        try await fixture.quiet()
        #expect(fixture.reloads == 0)
    }

    @Test func swappingALinkInTheMiddleOfAChainIsFollowed() async throws {
        let fixture = try WatchFixture()
        let first = try fixture.target("target-a")
        let second = try fixture.target("target-b")
        // config folder -> current -> target-a, with `current` beside the targets, not the folder.
        let current = fixture.root.appending(path: "current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: first)
        try fixture.link(to: current)
        fixture.start()
        let swap = fixture.root.appending(path: "swap")
        try FileManager.default.createSymbolicLink(at: swap, withDestinationURL: second)
        #expect(rename(swap.path, current.path) == 0)
        try await eventually { fixture.reloads >= 1 }
        try await fixture.quiet()
        #expect(fixture.reloads == 1)
        try fixture.rewriteInPlace("{\"dpi\": 800}")
        try await eventually { fixture.reloads >= 2 }
        try "{}".write(to: first.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try await fixture.quiet()
        #expect(fixture.reloads == 2)
    }

    @Test func destroyingAWatcherClosesItsDescriptors() async throws {
        let fixture = try WatchFixture()
        let first = try fixture.target("target-a")
        try fixture.link(to: first)
        var descriptors: [Int32] = []
        for _ in 0..<5 {
            let watcher = ConfigWatcher(url: fixture.config) {}
            watcher.start()
            descriptors += watcher.descriptors
        }
        #expect(descriptors.count >= 15)
        try await eventually { descriptors.allSatisfy { fcntl($0, F_GETFD) == -1 } }
    }

    @Test func stoppingAWatcherClosesItsDescriptorsAndEndsReloads() async throws {
        let fixture = try WatchFixture()
        try fixture.writeConfig()
        var count = 0
        let watcher = ConfigWatcher(url: fixture.config) { count += 1 }
        watcher.start()
        let descriptors = watcher.descriptors
        #expect(descriptors.count >= 3)
        try fixture.rewriteInPlace("{\"dpi\": 800}")
        watcher.stop()
        try await eventually { descriptors.allSatisfy { fcntl($0, F_GETFD) == -1 } }
        try await fixture.quiet()
        #expect(count == 0 && watcher.descriptors.isEmpty)
    }
}
