import Foundation
import Testing
@testable import PureMouseAppSupport

/// An in-memory world for the install pipeline: a disk of named blobs, a downloader, a mounter, a
/// signature checker and a file system that all log what they were asked, in order. Nothing here
/// reaches the network, `hdiutil` or Security.framework; the real ones are exercised by
/// `scripts/test-update-install.sh` with `codesign`-signed fixtures.
final class World: @unchecked Sendable {
    // Scripted behaviour.
    var imageHash = String(repeating: "a", count: 64)
    var sumsHash: String? = String(repeating: "a", count: 64)
    var downloadFails: Set<String> = []
    var oversize = false
    var attachFails = false
    var entries: [UpdateEntry] = [UpdateEntry(name: "PureMouse.app", kind: .directory), UpdateEntry(name: "Applications", kind: .symlink)]
    var version: String? = "0.6.0"
    var copyVersion: String?
    var requirement: String? = "REQ"
    var faults: [String: UpdateSignatureFault] = [:]   // "mount" or "copy"
    var replaceability = UpdateReplaceability.ok
    var copyFails = false
    /// What `replaceItemAt` does when it is asked.
    enum Replace { case works, throwsBefore, throwsAfter, throwsAndLeavesNoApp }
    var replace = Replace.works
    /// The version of the app at the install path: nil when there is none.
    var installedVersion: String? = "0.5.0"
    /// Left by an install that was killed.
    var stale: [URL] = []
    /// A downloader that does not hold to the limit it is given.
    var ignoresLimit = false
    var limits: [String: Int] = [:]
    /// Runs inside the install at "hash" or "copy", where a test can cancel the task.
    var at: [String: @Sendable () -> Void] = [:]

    // What happened.
    var events: [String] = []
    var disk: [URL: Data] = [:]
    var mounted: Set<URL> = []
    var checkedAgainst: [String] = []
    var work: URL?

    static let installed = URL(fileURLWithPath: "/Applications/PureMouse.app")
    static let release = UpdateCheck.Release(
        version: UpdateCheck.Version("0.6.0")!,
        page: URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0")!)

    var installer: UpdateInstaller {
        UpdateInstaller(downloader: Downloader(world: self), hasher: { [self] in
            events.append("hash")
            at["hash"]?()
            return disk[$0] == nil ? "" : imageHash
        }, mounter: Mounter(world: self), signature: Signature(world: self), files: Files(world: self))
    }

    func install(current: String = "0.5.0", app: URL? = World.installed) async -> UpdateInstallOutcome {
        await installer.install(Self.release, current: current, installedApp: app)
    }

    /// Whether any trace of the download or the mount, or of a staged copy, is left.
    var leftovers: Bool {
        !mounted.isEmpty || !disk.isEmpty
    }

    struct Downloader: UpdateDownloading {
        let world: World
        func download(_ url: URL, to file: URL, limit: Int) async throws {
            world.events.append("download \(url.lastPathComponent)")
            world.limits[url.lastPathComponent] = limit
            if world.downloadFails.contains(url.lastPathComponent) { throw URLError(.badServerResponse) }
            if url.lastPathComponent == "SHA256SUMS" {
                let line = world.sumsHash.map { "\($0)  PureMouse-0.6.0.dmg\n" } ?? "\(String(repeating: "f", count: 64))  Other.dmg\n"
                world.disk[file] = Data(line.utf8)
            } else {
                let count = world.oversize ? UpdateInstaller.maxImageBytes + 1 : 10
                if count > limit && !world.ignoresLimit { throw DownloadTooLarge() }
                world.disk[file] = Data(count: count)
            }
        }
    }

    struct Mounter: ImageMounting {
        let world: World
        func attach(_ image: URL, at mountPoint: URL) async throws {
            world.events.append("attach")
            if world.attachFails { throw ProcessFailure(tool: "hdiutil", status: 1) }
            world.mounted.insert(mountPoint)
        }
        func detach(_ mountPoint: URL) async {
            world.events.append("detach")
            world.mounted.remove(mountPoint)
        }
    }

    struct Signature: UpdateSignatureChecking {
        let world: World
        func requirement() -> String? { world.requirement }
        func check(_ bundle: URL, against requirement: String) -> UpdateSignatureFault? {
            let place = world.mounted.contains(where: { bundle.path.hasPrefix($0.path) }) ? "mount"
                : bundle == World.installed ? "installed" : "copy"
            world.events.append("check \(place)")
            world.checkedAgainst.append(requirement)
            return world.faults[place]
        }
        func checkImage(_ image: URL, against requirement: String) -> UpdateSignatureFault? {
            world.events.append("check image")
            world.checkedAgainst.append(requirement)
            return world.faults["image"]
        }
    }

    struct Files: UpdateFiles {
        let world: World
        func makeWorkDirectory() throws -> URL {
            let directory = URL(fileURLWithPath: "/tmp/PureMouse-update-fake", isDirectory: true)
            world.work = directory
            return directory
        }
        func makeDirectory(_ url: URL) throws {}
        func size(of file: URL) -> Int? { world.disk[file]?.count }
        func contents(of file: URL) throws -> Data {
            guard let data = world.disk[file] else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
        func entries(of directory: URL) throws -> [UpdateEntry] { world.entries }
        func bundleVersion(_ bundle: URL) -> String? {
            if bundle == World.installed { return world.installedVersion }
            return bundle.path.hasPrefix(World.installed.deletingLastPathComponent().appending(path: ".PureMouse-update").path)
                ? (world.copyVersion ?? world.version) : world.version
        }
        func replaceability(of app: URL) -> UpdateReplaceability { world.replaceability }
        func copy(_ source: URL, to destination: URL) async throws {
            world.events.append("copy")
            world.at["copy"]?()
            if world.copyFails { throw CocoaError(.fileWriteOutOfSpace) }
            world.disk[destination] = Data()
        }
        func replace(_ installed: URL, with staged: URL) throws {
            world.events.append("replace")
            switch world.replace {
            case .works:
                world.installedVersion = world.copyVersion ?? world.version
                world.disk[staged] = nil
            case .throwsBefore:
                throw CocoaError(.fileWriteNoPermission)
            case .throwsAfter:   // Cocoa 513 with the new app in place and the old one left at `staged`
                world.installedVersion = world.copyVersion ?? world.version
                throw CocoaError(.fileWriteNoPermission)
            case .throwsAndLeavesNoApp:
                world.installedVersion = nil
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        func leftovers(besides app: URL) -> [URL] { world.stale }
        func remove(_ url: URL) {
            world.events.append("remove \(url.lastPathComponent.hasPrefix(".PureMouse-update") ? "staged" : url.lastPathComponent == "PureMouse-update-stale" ? "stale" : "work")")
            world.disk = world.disk.filter { !$0.key.path.hasPrefix(url.path) }
        }
    }
}

@Suite struct UpdateInstallTests {
    private func untouched(_ world: World) -> Bool {
        !world.events.contains("replace") && !world.events.contains("copy")
    }

    @Test func aGoodReleaseIsVerifiedInOrderCopiedBesideTheAppAndSwappedIn() async {
        let world = World()
        let outcome = await world.install()
        #expect(outcome == .installed(UpdateCheck.Version("0.6.0")!))
        #expect(world.events == ["download SHA256SUMS", "download PureMouse-0.6.0.dmg", "hash", "check image", "attach",
                                 "check mount", "copy", "check copy", "replace", "detach", "remove work"])
        // The requirement is the running app's, handed to both checks unchanged.
        #expect(world.checkedAgainst == ["REQ", "REQ", "REQ"])
        #expect(!world.leftovers)
    }

    @Test func theAssetsComeFromTheReleaseThatWasFound() async {
        let world = World()
        var requested: [URL] = []
        struct Spy: UpdateDownloading {
            let inner: UpdateDownloading
            let record: @Sendable (URL) -> Void
            func download(_ url: URL, to file: URL, limit: Int) async throws { record(url); try await inner.download(url, to: file, limit: limit) }
        }
        final class Box: @unchecked Sendable { var urls: [URL] = [] }
        let box = Box()
        var installer = world.installer
        installer.downloader = Spy(inner: installer.downloader) { box.urls.append($0) }
        _ = await installer.install(World.release, current: "0.5.0", installedApp: World.installed)
        requested = box.urls
        #expect(requested.map(\.absoluteString) == [
            "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0/SHA256SUMS",
            "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0/PureMouse-0.6.0.dmg"])
    }

    @Test func aHashThatDoesNotMatchStopsBeforeTheImageIsMounted() async {
        let world = World()
        world.imageHash = String(repeating: "b", count: 64)
        #expect(await world.install() == .failed(.checksumMismatch))
        #expect(!world.events.contains("attach") && untouched(world))
        #expect(!world.leftovers)
    }

    @Test func aReleaseWithNoChecksumLineIsRefused() async {
        let world = World()
        world.sumsHash = nil
        #expect(await world.install() == .failed(.checksumMissing))
        #expect(!world.events.contains("attach") && !world.leftovers)
    }

    @Test(arguments: ["SHA256SUMS", "PureMouse-0.6.0.dmg"])
    func aDownloadThatFailsLeavesNothing(_ name: String) async {
        let world = World()
        world.downloadFails = [name]
        #expect(await world.install() == .failed(.downloadFailed))
        #expect(untouched(world) && !world.leftovers)
    }

    @Test func anImageBeyondTheSizeCapIsNotHashedOrMounted() async {
        let world = World()
        world.oversize = true
        #expect(await world.install() == .failed(.downloadFailed))
        #expect(!world.events.contains("hash") && !world.events.contains("attach") && !world.leftovers)
    }

    @Test func theCapsAreHandedToTheDownloaderToHoldDuringTheTransfer() async {
        let world = World()
        _ = await world.install()
        #expect(world.limits == ["SHA256SUMS": UpdateInstaller.maxChecksumBytes, "PureMouse-0.6.0.dmg": UpdateInstaller.maxImageBytes])
    }

    @Test func aDownloaderThatIgnoresTheLimitIsStillStoppedByTheSizeCheck() async {
        let world = World()
        world.oversize = true
        world.ignoresLimit = true
        #expect(await world.install() == .failed(.downloadFailed))
        #expect(!world.events.contains("hash") && !world.leftovers)
    }

    @Test(arguments: [UpdateSignatureFault.unsigned, .wrongCertificate, .modified])
    func anImageNotSignedByTheRunningCertificateIsNeverMounted(_ fault: UpdateSignatureFault) async {
        let world = World()
        world.faults["image"] = fault
        #expect(await world.install() == .failed(UpdateInstaller.failure(fault)))
        #expect(!world.events.contains("attach") && !world.events.contains("check mount") && untouched(world))
        #expect(!world.leftovers)
    }

    @Test func leftoversOfAnEarlierInstallAreSweptBeforeDownloading() async {
        let world = World()
        world.stale = [URL(fileURLWithPath: "/Applications/.PureMouse-update-abc12345"),
                       URL(fileURLWithPath: "/tmp/PureMouse-update-stale")]
        _ = await world.install()
        let first = world.events.firstIndex(of: "download SHA256SUMS")!
        #expect(world.events[..<first].filter { $0 == "remove staged" || $0 == "remove stale" }.count == 2)
    }

    @Test func aPreservedCopyIsKeptAndNothingDownloadsWhenTheInstalledAppDoesNotVerify() async {
        let world = World()
        let kept = URL(fileURLWithPath: "/Applications/.PureMouse-update-abc12345")
        world.stale = [kept, URL(fileURLWithPath: "/tmp/PureMouse-update-stale")]
        world.disk[kept] = Data()
        world.faults["installed"] = .modified
        let outcome = await world.install()
        #expect(outcome == .failed(.cannotInstallHere(.damaged)))
        #expect(outcome == .failed(.cannotInstallHere(.damaged)) && UpdateInstallFailure.cannotInstallHere(.damaged).opensReleasePage)
        #expect(world.disk[kept] != nil && !world.events.contains("remove staged"))
        #expect(!world.events.contains { $0.hasPrefix("download") })
    }

    @Test func aPreservedCopyIsKeptWhenTheInstalledAppHasNoReadableVersion() async {
        let world = World()
        let kept = URL(fileURLWithPath: "/Applications/.PureMouse-update-abc12345")
        world.stale = [kept]
        world.disk[kept] = Data()
        world.installedVersion = nil
        #expect(await world.install() == .failed(.cannotInstallHere(.damaged)))
        #expect(world.disk[kept] != nil && !world.events.contains { $0.hasPrefix("download") })
    }

    @Test func aPreservedCopyIsSweptOnlyAfterTheInstalledAppVerifies() async {
        let world = World()
        world.stale = [URL(fileURLWithPath: "/Applications/.PureMouse-update-abc12345")]
        _ = await world.install()
        let checked = world.events.firstIndex(of: "check installed")!
        #expect(checked < world.events.firstIndex(of: "remove staged")!)
        #expect(checked < world.events.firstIndex(of: "download SHA256SUMS")!)
    }

    @Test func aRunThatCannotInstallSweepsNothing() async {
        let world = World()
        world.stale = [URL(fileURLWithPath: "/tmp/PureMouse-update-stale")]
        world.replaceability = .notWritable
        _ = await world.install()
        #expect(world.events.isEmpty)
    }

    @Test func anImageThatWillNotMountIsDetachedAndForgotten() async {
        let world = World()
        world.attachFails = true
        #expect(await world.install() == .failed(.imageUnreadable))
        #expect(world.events.contains("detach") && untouched(world) && !world.leftovers)
    }

    @Test(arguments: [
        [UpdateEntry(name: "Applications", kind: .symlink)],
        [UpdateEntry(name: "PureMouse.app", kind: .directory), UpdateEntry(name: "Other.app", kind: .directory)],
        [UpdateEntry(name: "PureMouse.app", kind: .directory), UpdateEntry(name: "pureMouse 2.APP", kind: .directory)],
        [UpdateEntry(name: "PureMouse.app", kind: .symlink)],
        [UpdateEntry(name: "PureMouse.app", kind: .other)],
        [UpdateEntry(name: "Evil.app", kind: .directory)],
    ])
    func anImageWithoutExactlyOnePureMouseAppIsRefused(_ entries: [UpdateEntry]) async {
        let world = World()
        world.entries = entries
        #expect(await world.install() == .failed(.imageContents))
        #expect(!world.events.contains("check mount") && untouched(world) && !world.leftovers)
    }

    @Test(arguments: [(UpdateSignatureFault.unsigned, UpdateInstallFailure.unsigned),
                      (.wrongCertificate, .wrongCertificate), (.modified, .modified)])
    func aBadSignatureLeavesTheInstalledAppAlone(_ fault: UpdateSignatureFault, _ failure: UpdateInstallFailure) async {
        let world = World()
        world.faults["mount"] = fault
        #expect(await world.install() == .failed(failure))
        #expect(untouched(world) && !world.leftovers)
        #expect(world.events.last == "remove work")
    }

    @Test(arguments: ["0.5.0", "0.4.9", "0.5"])
    func aVersionThatIsNotNewerIsRefused(_ version: String) async {
        let world = World()
        world.version = version
        #expect(await world.install(current: "0.5.0") == .failed(.notNewer))
        #expect(untouched(world) && !world.leftovers)
    }

    @Test func aNewerBundleOfAnotherVersionIsNotTheRelease() async {
        let world = World()
        world.version = "0.7.0"
        #expect(await world.install() == .failed(.notTheRelease))
        #expect(untouched(world) && !world.leftovers)
    }

    @Test func aBundleWithNoVersionIsNotNewer() async {
        let world = World()
        world.version = nil
        #expect(await world.install() == .failed(.notNewer))
    }

    @Test func theSignatureIsCheckedBeforeTheVersionIsTrusted() async {
        let world = World()
        world.version = "0.5.0"
        world.faults["mount"] = .wrongCertificate
        #expect(await world.install() == .failed(.wrongCertificate))
    }

    @Test func aCopyThatNoLongerVerifiesIsDeletedNotSwapped() async {
        let world = World()
        world.faults["copy"] = .modified
        #expect(await world.install() == .failed(.modified))
        #expect(!world.events.contains("replace"))
        #expect(world.events.contains("remove staged") && !world.leftovers)
    }

    @Test func aCopyWhoseVersionChangedIsDeletedNotSwapped() async {
        let world = World()
        world.copyVersion = "0.9.0"
        #expect(await world.install() == .failed(.modified))
        #expect(!world.events.contains("replace") && world.events.contains("remove staged") && !world.leftovers)
    }

    @Test func aCopyThatFailsLeavesNothing() async {
        let world = World()
        world.copyFails = true
        #expect(await world.install() == .failed(.installFailed))
        #expect(!world.events.contains("replace") && !world.leftovers)
    }

    @Test func aSwapThatFailsBeforeCommittingRemovesTheStagedCopyAndTheDownload() async {
        let world = World()
        world.replace = .throwsBefore
        #expect(await world.install() == .failed(.installFailed))
        #expect(world.events.contains("remove staged") && !world.leftovers)
        #expect(world.installedVersion == "0.5.0")
    }

    @Test func aSwapThatThrowsAfterCommittingIsAnInstallAndTheOldCopyIsSwept() async {
        let world = World()
        world.replace = .throwsAfter
        #expect(await world.install() == .installed(UpdateCheck.Version("0.6.0")!))
        // The disk was read: the app at the install path is the new one and verifies.
        #expect(world.events.contains("check installed") && world.installedVersion == "0.6.0")
        #expect(world.events.contains("remove staged") && !world.leftovers)
    }

    @Test func aSwapThatThrowsAfterCommittingButDoesNotVerifyKeepsTheStagedCopy() async {
        let world = World()
        world.replace = .throwsAfter
        world.faults["installed"] = .modified
        #expect(await world.install() == .failed(.installFailed))
        #expect(!world.events.contains("remove staged"))
        #expect(world.disk.keys.contains { $0.lastPathComponent.hasPrefix(".PureMouse-update") })
    }

    @Test func aSwapThatThrowsBeforeCommittingButLeavesADamagedOldAppKeepsTheStagedCopy() async {
        let world = World()
        world.replace = .throwsBefore
        world.faults["installed"] = .modified   // the old bundle kept its Info.plist but fails its signature
        #expect(await world.install() == .failed(.installFailed))
        #expect(world.events.contains("check installed") && !world.events.contains("remove staged"))
        #expect(world.disk.keys.contains { $0.lastPathComponent.hasPrefix(".PureMouse-update") })
    }

    @Test func aSwapThatThrowsBeforeCommittingWithTheOldAppVerifyingRemovesTheStagedCopy() async {
        let world = World()
        world.replace = .throwsBefore
        #expect(await world.install() == .failed(.installFailed))
        #expect(world.events.contains("check installed") && world.events.contains("remove staged"))
    }

    @Test func aSwapThatLeavesNoAppAtTheInstallPathKeepsTheOnlyCopyThereIs() async {
        let world = World()
        world.replace = .throwsAndLeavesNoApp
        #expect(await world.install() == .failed(.installFailed))
        #expect(!world.events.contains("remove staged"))
        #expect(world.disk.keys.contains { $0.lastPathComponent.hasPrefix(".PureMouse-update") })
        #expect(world.events.last == "remove work")
    }

    @Test(arguments: ["hash", "copy"])
    func cancellingStopsBeforeTheSwapAndCleansUpEverything(_ step: String) async {
        let world = World()
        world.at[step] = { withUnsafeCurrentTask { $0?.cancel() } }
        #expect(await world.install() == .failed(.cancelled))
        #expect(untouched(world) || world.events.contains("copy"))
        #expect(!world.events.contains("replace") && !world.leftovers)
        #expect(world.events.last == "remove work")
        if step == "hash" { #expect(!world.events.contains("attach")) }
    }

    @Test func aSuccessfulSwapDoesNotDeleteTheNewApp() async {
        let world = World()
        _ = await world.install()
        #expect(!world.events.contains("remove staged"))
    }

    @Test(arguments: [(UpdateReplaceability.notWritable, UpdateInstallFailure.Place.notWritable),
                      (.readOnlyVolume, .readOnlyVolume)])
    func anAppThatCannotBeReplacedOpensTheReleasePageBeforeAnythingIsDownloaded(
        _ replaceability: UpdateReplaceability, _ place: UpdateInstallFailure.Place) async {
        let world = World()
        world.replaceability = replaceability
        let outcome = await world.install()
        #expect(outcome == .failed(.cannotInstallHere(place)))
        guard case .failed(let failure) = outcome else { return }
        #expect(failure.opensReleasePage)
        #expect(world.events.isEmpty && world.work == nil)
    }

    @Test func aRunThatCannotBeCheckedOrReplacedDownloadsNothing() async {
        let none = World()
        #expect(await none.install(app: nil) == .failed(.cannotInstallHere(.notInstalled)))
        let dev = World()
        #expect(await dev.install(current: "dev") == .failed(.cannotInstallHere(.developmentBuild)))
        let unsigned = World()
        unsigned.requirement = nil
        #expect(await unsigned.install() == .failed(.cannotInstallHere(.notSigned)))
        #expect(none.events.isEmpty && dev.events.isEmpty && unsigned.events.isEmpty)
    }

    @Test func aReleasePageThatIsNotATagPageDownloadsNothing() async {
        let world = World()
        let odd = UpdateCheck.Release(version: World.release.version,
                                      page: URL(string: "https://github.com/mblauberg/PureMouse/releases/latest")!)
        let outcome = await world.installer.install(odd, current: "0.5.0", installedApp: World.installed)
        #expect(outcome == .failed(.downloadFailed) && world.events.isEmpty)
    }

    @Test func onlyAFailureToInstallHereOpensThePageByItself() {
        let all: [UpdateInstallFailure] = [.downloadFailed, .checksumMissing, .checksumMismatch, .imageUnreadable, .imageContents,
                                           .unsigned, .wrongCertificate, .modified, .notNewer, .notTheRelease, .installFailed]
        #expect(all.allSatisfy { !$0.opensReleasePage })
        #expect(all.allSatisfy { !$0.reason.contains("\n") && $0.reason.count < 60 })
    }
}

@Suite struct UpdateAssetsAndChecksumTests {
    private func release(_ page: String) -> UpdateCheck.Release {
        UpdateCheck.Release(version: UpdateCheck.Version("0.6.0")!, page: URL(string: page)!)
    }

    @Test func assetsAreFoundFromTheTagPage() {
        let assets = UpdateAssets(release("https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0-rc.1"))
        #expect(assets?.imageName == "PureMouse-0.6.0-rc.1.dmg")
        #expect(assets?.image.absoluteString == "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0-rc.1/PureMouse-0.6.0-rc.1.dmg")
        #expect(assets?.sums.absoluteString == "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0-rc.1/SHA256SUMS")
    }

    @Test(arguments: [
        "https://github.com/mblauberg/PureMouse/releases/latest",
        "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0/extra",
        "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0",
        "https://github.com/mblauberg/PureMouse/releases/tag/evil",
        "https://github.com/mblauberg/PureMouse/releases/tag/v0.6.0%2F..%2Fx",
        "https://github.com/other/PureMouse/releases/tag/v0.6.0",
        "http://github.com/mblauberg/PureMouse/releases/tag/v0.6.0",
        "https://example.com/mblauberg/PureMouse/releases/tag/v0.6.0",
    ])
    func otherPagesGiveNoAssets(_ page: String) {
        #expect(UpdateAssets(release(page)) == nil)
    }

    private let hash = String(repeating: "ab", count: 32)

    @Test func theChecksumIsTheLineForExactlyTheImage() {
        let data = Data("\(hash)  PureMouse-0.6.0.dmg\n\(String(repeating: "cd", count: 32))  PureMouse-0.5.0.dmg\n".utf8)
        #expect(Checksums.hash(for: "PureMouse-0.6.0.dmg", in: data) == hash)
        #expect(Checksums.hash(for: "PureMouse-0.6.dmg", in: data) == nil)
        #expect(Checksums.hash(for: "PureMouse-0.7.0.dmg", in: data) == nil)
    }

    @Test func aBinaryMarkerUppercaseAndTabsAreRead() {
        let data = Data("\(hash.uppercased())\t*PureMouse-0.6.0.dmg\r\n".utf8)
        #expect(Checksums.hash(for: "PureMouse-0.6.0.dmg", in: data) == hash)
    }

    @Test func aMalformedOrContradictoryLineGivesNothing() {
        #expect(Checksums.hash(for: "a.dmg", in: Data("abc  a.dmg".utf8)) == nil)
        #expect(Checksums.hash(for: "a.dmg", in: Data("\(String(repeating: "z", count: 64))  a.dmg".utf8)) == nil)
        let two = "\(hash)  a.dmg\n\(String(repeating: "cd", count: 32))  a.dmg\n"
        #expect(Checksums.hash(for: "a.dmg", in: Data(two.utf8)) == nil)
        let same = "\(hash)  a.dmg\n\(hash)  a.dmg\n"
        #expect(Checksums.hash(for: "a.dmg", in: Data(same.utf8)) == hash)
        #expect(Checksums.hash(for: "a.dmg", in: Data()) == nil)
    }
}

@Suite struct SigningRequirementTests {
    private let menu = "io.github.mblauberg.puremouse.menu"
    private let leaf = #"certificate leaf = H"7664652a1e98aa55498d5b8394add64b6a67d463""#

    @Test func aNestedAppsRequirementBecomesTheAppsWithTheSameCertificate() {
        let requirement = SigningRequirement.forApp(designated: "identifier \"\(menu)\" and \(leaf)", runningIdentifier: menu)
        #expect(requirement == "identifier \"io.github.mblauberg.puremouse\" and (\(leaf))")
    }

    @Test func theAppsOwnRequirementIsKept() {
        let app = SigningRequirement.appIdentifier
        #expect(SigningRequirement.forApp(designated: "identifier \"\(app)\" and \(leaf)", runningIdentifier: app)
                == "identifier \"\(app)\" and (\(leaf))")
    }

    @Test func aDeveloperIDRequirementKeepsItsTeam() {
        let pin = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ABCDE12345"#
        let requirement = SigningRequirement.forApp(designated: "identifier \"\(menu)\" and \(pin)", runningIdentifier: menu)
        #expect(requirement == "identifier \"io.github.mblauberg.puremouse\" and (\(pin))")
    }

    @Test(arguments: [
        #"cdhash H"0123456789012345678901234567890123456789""#,                      // ad hoc
        #"identifier "other" and certificate leaf = H"7664652a""#,                     // not this process's identifier
        #"identifier "io.github.mblauberg.puremouse.menu" and anchor apple"#,          // Apple's, no team
        #"identifier "io.github.mblauberg.puremouse.menu" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */"#,
        #"identifier "io.github.mblauberg.puremouse.menu" and certificate leaf = H"ab" or identifier "x""#,
        #"identifier "io.github.mblauberg.puremouse.menu" and certificate leaf = H"zz""#,
        #"identifier "io.github.mblauberg.puremouse.menu" and true"#,
        "",
    ])
    func anythingElseHasNoCertificateToPin(_ designated: String) {
        #expect(SigningRequirement.forApp(designated: designated, runningIdentifier: menu) == nil)
    }

    @Test func noRunningIdentifierGivesNothing() {
        #expect(SigningRequirement.forApp(designated: "identifier \"\" and \(leaf)", runningIdentifier: nil) == nil)
        #expect(SigningRequirement.forApp(designated: "identifier \"\" and \(leaf)", runningIdentifier: "") == nil)
    }

    @Test func theTestProcessIsNotAPureMouseAppAndHasNothingToPin() {
        #expect(CodeSignatureChecker().requirement() == nil)
    }

    @Test func aSecurityStatusBecomesTheFaultItNames() {
        #expect(CodeSignatureChecker.fault(errSecSuccess) == nil)
        #expect(CodeSignatureChecker.fault(errSecCSUnsigned) == .unsigned)
        #expect(CodeSignatureChecker.fault(errSecCSReqFailed) == .wrongCertificate)
        #expect(CodeSignatureChecker.fault(errSecCSSignatureFailed) == .modified)
        #expect(CodeSignatureChecker.fault(errSecCSBadResource) == .modified)
    }

    @Test func aMissingBundleOrABrokenRequirementIsRefused() {
        let checker = CodeSignatureChecker()
        #expect(checker.check(URL(fileURLWithPath: "/nonexistent/PureMouse.app"), against: "identifier \"x\"") != nil)
        #expect(checker.check(URL(fileURLWithPath: "/usr/bin"), against: "this is not (a requirement") != nil)
    }
}

@Suite struct LiveUpdateFilesTests {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func app(in directory: URL) throws -> URL {
        let app = directory.appending(path: "PureMouse.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: app.appending(path: "Contents/MacOS/puremouse"))
        return app
    }

    private func lock(_ url: URL) { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path) }
    private func unlock(_ url: URL) { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }

    @Test func aWritableAppInAWritableFolderCanBeReplaced() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LiveUpdateFiles().replaceability(of: try app(in: directory)) == .ok)
    }

    @Test func aFolderOrAnInnerFolderTheUserCannotWriteBlocksIt() throws {
        let directory = try temporary()
        let app = try app(in: directory)
        defer { unlock(directory); unlock(app.appending(path: "Contents/MacOS")); try? FileManager.default.removeItem(at: directory) }
        lock(app.appending(path: "Contents/MacOS"))   // as an administrator's copy leaves it
        #expect(LiveUpdateFiles().replaceability(of: app) == .notWritable)
        unlock(app.appending(path: "Contents/MacOS"))
        lock(directory)
        #expect(LiveUpdateFiles().replaceability(of: app) == .notWritable)
    }

    @Test func aTranslocatedCopyCountsAsReadOnly() {
        let moved = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/PureMouse.app")
        #expect(LiveUpdateFiles().replaceability(of: moved) == .readOnlyVolume)
    }

    @Test func theSwapReplacesTheAppInOneStepAndKeepsItsName() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try app(in: directory)
        let staged = directory.appending(path: ".PureMouse-update-x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staged.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("2".utf8).write(to: staged.appending(path: "Contents/MacOS/puremouse"))
        try LiveUpdateFiles().replace(installed, with: staged)
        #expect(try String(contentsOf: installed.appending(path: "Contents/MacOS/puremouse"), encoding: .utf8) == "2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["PureMouse.app"])
    }

    @Test func aFailedSwapKeepsTheInstalledApp() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try app(in: directory)
        #expect(throws: (any Error).self) {
            try LiveUpdateFiles().replace(installed, with: directory.appending(path: "missing"))
        }
        #expect(try String(contentsOf: installed.appending(path: "Contents/MacOS/puremouse"), encoding: .utf8) == "1")
    }

    @Test func entriesNameSymlinksAndFoldersAndTheWorkFolderIsPrivate() throws {
        let files = LiveUpdateFiles()
        let work = try files.makeWorkDirectory()
        defer { files.remove(work) }
        #expect(((try FileManager.default.attributesOfItem(atPath: work.path))[.posixPermissions] as? Int) == 0o700)
        try FileManager.default.createDirectory(at: work.appending(path: "PureMouse.app"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: work.appending(path: "Applications").path, withDestinationPath: "/Applications")
        try Data().write(to: work.appending(path: "x"))
        let entries = try files.entries(of: work).sorted { $0.name < $1.name }
        #expect(entries == [UpdateEntry(name: "Applications", kind: .symlink), UpdateEntry(name: "PureMouse.app", kind: .directory),
                            UpdateEntry(name: "x", kind: .other)])
        files.remove(work)
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test func theBundleVersionIsReadFromItsInfoPlist() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try app(in: directory)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        #expect(LiveUpdateFiles().bundleVersion(bundle) == "1.2.3")
        #expect(LiveUpdateFiles().bundleVersion(directory) == nil)
    }

    @Test func sha256MatchesTheKnownDigest() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        #expect(try Sha256.hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = directory.appending(path: "big")
        try Data(repeating: 0x61, count: 3 * (1 << 20) + 7).write(to: big)
        #expect(try Sha256.hex(of: big).count == 64)
    }
}

@Suite struct InstalledAppLocationTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func theInstalledAppIsTheOneTheDaemonLivesIn() {
        for nested in ["/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app",
                       "/Applications/PureMouse.app/Contents/Helpers/PureMouse Settings.app"] {
            let locations = Locations(environment: [:], home: home, bundle: URL(fileURLWithPath: nested), isExecutable: { _ in true })
            #expect(locations.installedApp?.path == "/Applications/PureMouse.app")
        }
    }

    @Test func aDevelopmentRunHasNoInstalledApp() {
        let bundle = URL(fileURLWithPath: "/Applications/PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app")
        #expect(Locations(environment: [:], home: home, bundle: bundle, isExecutable: { _ in false }).installedApp == nil)
        #expect(Locations(environment: ["PUREMOUSE_DAEMON": "/tmp/stub"], home: home, bundle: bundle,
                          isExecutable: { _ in true }).installedApp == nil)
        let bare = URL(fileURLWithPath: "/Users/someone/PureMouse/.build/debug/PureMouseMenu")
        #expect(Locations(environment: [:], home: home, bundle: bare, isExecutable: { _ in true }).installedApp == nil)
    }
}

/// Answers every request from a script, so the real downloader runs without a network.
final class ScriptedResponse: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var declaredLength: Int?
    nonisolated(unsafe) static var chunks: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var headers: [String: String] = [:]
        if let length = Self.declaredLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct EphemeralDownloaderTests {
    private let url = URL(string: "https://github.com/mblauberg/PureMouse/releases/download/v0.6.0/PureMouse-0.6.0.dmg")!

    private func run(status: Int = 200, declared: Int? = nil, chunks: [Data], limit: Int) async throws -> (file: URL, data: Data?) {
        ScriptedResponse.status = status
        ScriptedResponse.declaredLength = declared
        ScriptedResponse.chunks = chunks
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "out")
        try await EphemeralDownloader(protocols: [ScriptedResponse.self]).download(url, to: file, limit: limit)
        return (file, try? Data(contentsOf: file))
    }

    private func cleanup(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    @Test func aBodyWithinTheLimitIsWrittenWhole() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let result = try await run(declared: body.count, chunks: [body.prefix(70_000), body.dropFirst(70_000)].map { Data($0) }, limit: 300_000)
        defer { cleanup(result.file) }
        #expect(result.data == body)
    }

    @Test func aPromiseOfMoreThanTheLimitIsRefusedBeforeAnythingIsWritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ScriptedResponse.status = 200
        ScriptedResponse.declaredLength = 5_000
        ScriptedResponse.chunks = [Data(count: 10)]
        let file = directory.appending(path: "out")
        await #expect(throws: DownloadTooLarge.self) {
            try await EphemeralDownloader(protocols: [ScriptedResponse.self]).download(url, to: file, limit: 1_000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBodyThatGrowsPastTheLimitIsCutOffAndItsPartialFileDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ScriptedResponse.status = 200
        ScriptedResponse.declaredLength = nil          // chunked: the length is not known up front
        ScriptedResponse.chunks = Array(repeating: Data(count: 50_000), count: 6)
        let file = directory.appending(path: "out")
        await #expect(throws: DownloadTooLarge.self) {
            try await EphemeralDownloader(protocols: [ScriptedResponse.self]).download(url, to: file, limit: 200_000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBodyThatIsExactlyTheLimitIsAccepted() async throws {
        let result = try await run(declared: 1_000, chunks: [Data(count: 1_000)], limit: 1_000)
        defer { cleanup(result.file) }
        #expect(result.data?.count == 1_000)
    }

    @Test func anythingButOKIsRefusedAndWritesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ScriptedResponse.status = 404
        ScriptedResponse.declaredLength = 10
        ScriptedResponse.chunks = [Data(count: 10)]
        let file = directory.appending(path: "out")
        await #expect(throws: URLError.self) {
            try await EphemeralDownloader(protocols: [ScriptedResponse.self]).download(url, to: file, limit: 1_000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func plainHTTPIsRefused() async {
        await #expect(throws: URLError.self) {
            try await EphemeralDownloader().download(URL(string: "http://github.com/x")!, to: URL(fileURLWithPath: "/nonexistent/x"), limit: 10)
        }
    }
}

@Suite struct ImageRequirementTests {
    private let leaf = #"certificate leaf = H"7664652a1e98aa55498d5b8394add64b6a67d463""#

    @Test func aDiskImageIsHeldToTheCertificateAndNotTheAppsIdentifier() {
        let requirement = "identifier \"\(SigningRequirement.appIdentifier)\" and (\(leaf))"
        #expect(SigningRequirement.certificate(of: requirement) == "(\(leaf))")
    }

    @Test(arguments: ["", "identifier \"other\" and (certificate leaf = H\"ab\")", "certificate leaf = H\"ab\"",
                      "identifier \"io.github.mblauberg.puremouse\" and certificate leaf = H\"ab\""])
    func anyOtherTextHasNoCertificatePart(_ text: String) {
        #expect(SigningRequirement.certificate(of: text) == nil)
    }

    @Test func anUnsignedOrMissingImageIsRefused() throws {
        let checker = CodeSignatureChecker()
        let requirement = "identifier \"\(SigningRequirement.appIdentifier)\" and (\(leaf))"
        #expect(checker.checkImage(URL(fileURLWithPath: "/nonexistent/x.dmg"), against: requirement) != nil)
        let file = FileManager.default.temporaryDirectory.appending(path: "pm-img-\(UUID().uuidString).dmg")
        try Data(count: 4096).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(checker.checkImage(file, against: requirement) != nil)
        #expect(checker.checkImage(file, against: "not a requirement") == .wrongCertificate)
    }
}

@Suite struct LiveCommitPointTests {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pm-commit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A bundle with a version and one executable.
    private func bundle(_ url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: url.appending(path: "Contents/MacOS/puremouse"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
    }

    /// Clears what a test set so its folder can be deleted.
    private func clean(_ directory: URL) {
        LiveUpdateFiles().remove(directory)
    }

    private func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// The installer over the real file system, with the signature check always passing: only where
    /// the disk says each app is, and what is deleted, are under test.
    private var installer: UpdateInstaller {
        var installer = World().installer
        installer.files = LiveUpdateFiles()
        return installer
    }

    private let old = UpdateCheck.Version("0.5.0")!
    private let new = UpdateCheck.Version("0.6.0")!

    /// Makes `PureMouse.app` (0.5.0) with its executable made impossible to delete, and a staged 0.6.0.
    private func staged(_ harden: (URL) throws -> Void) throws -> (directory: URL, installed: URL, staged: URL) {
        let directory = try temporary()
        let installed = directory.appending(path: "PureMouse.app", directoryHint: .isDirectory)
        let staged = directory.appending(path: ".PureMouse-update-x", directoryHint: .isDirectory)
        try bundle(installed, version: "0.5.0")
        try bundle(staged, version: "0.6.0")
        try harden(installed.appending(path: "Contents/MacOS/puremouse"))
        return (directory, installed, staged)
    }

    @Test func anImmutableResourceMakesTheSwapThrowAfterTheNewAppIsInPlaceAndTheDiskSaysSo() throws {
        let world = try staged { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: $0.path) }
        defer { clean(world.directory) }
        let files = LiveUpdateFiles()
        // Nothing before the swap notices: the folders are writable.
        #expect(files.replaceability(of: world.installed) == .ok)
        #expect(throws: (any Error).self) { try files.replace(world.installed, with: world.staged) }
        // The new app is installed and the old one is left at the staged path.
        #expect(files.bundleVersion(world.installed) == "0.6.0" && files.bundleVersion(world.staged) == "0.5.0")
        #expect(installer.settle(world.installed, running: old, found: new, requirement: "REQ") == .new)
        // Cleaning up the leftover old copy clears what held it.
        installer.files.remove(world.staged)
        #expect(!FileManager.default.fileExists(atPath: world.staged.path))
        #expect(files.bundleVersion(world.installed) == "0.6.0")
    }

    @Test func aDenyDeleteACLDoesTheSame() throws {
        let world = try staged { try chmod(["+a", "everyone deny delete", $0.path]) }
        defer { clean(world.directory) }
        let files = LiveUpdateFiles()
        #expect(files.replaceability(of: world.installed) == .ok)
        #expect(throws: (any Error).self) { try files.replace(world.installed, with: world.staged) }
        #expect(files.bundleVersion(world.installed) == "0.6.0" && files.bundleVersion(world.staged) == "0.5.0")
        #expect(installer.settle(world.installed, running: old, found: new, requirement: "REQ") == .new)
        installer.files.remove(world.staged)
        #expect(!FileManager.default.fileExists(atPath: world.staged.path))
    }

    @Test func aSwapThatFailsBeforeAnythingMovedLeavesTheOldAppAndTheDiskSaysSo() throws {
        let world = try staged { _ in }
        defer { clean(world.directory) }
        #expect(throws: (any Error).self) {
            try LiveUpdateFiles().replace(world.installed, with: world.directory.appending(path: "missing"))
        }
        #expect(installer.settle(world.installed, running: old, found: new, requirement: "REQ") == .old)
    }

    @Test func aMissingAppIsUnknownSoNothingIsDeleted() throws {
        let world = try staged { _ in }
        defer { clean(world.directory) }
        try FileManager.default.removeItem(at: world.installed)
        #expect(installer.settle(world.installed, running: old, found: new, requirement: "REQ") == .unknown)
        // An app of some third version is unknown as well.
        try bundle(world.installed, version: "0.9.9")
        #expect(installer.settle(world.installed, running: old, found: new, requirement: "REQ") == .unknown)
    }

    @Test func swappingRemovesWhatWasInstalledAndLeavesNoHiddenFolderBehind() throws {
        let world = try staged { _ in }
        defer { clean(world.directory) }
        try LiveUpdateFiles().replace(world.installed, with: world.staged)
        #expect(LiveUpdateFiles().bundleVersion(world.installed) == "0.6.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.directory.path) == ["PureMouse.app"])
    }

    @Test func copyKeepsHardLinksSoTheAssetCatalogShipsOnce() async throws {
        let directory = try temporary()
        defer { clean(directory) }
        let source = directory.appending(path: "src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source.appending(path: "a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appending(path: "b"), withIntermediateDirectories: true)
        try Data("car".utf8).write(to: source.appending(path: "a/Assets.car"))
        try FileManager.default.linkItem(at: source.appending(path: "a/Assets.car"), to: source.appending(path: "b/Assets.car"))
        let copy = directory.appending(path: "dst", directoryHint: .isDirectory)
        try await LiveUpdateFiles().copy(source, to: copy)
        func inode(_ url: URL) throws -> UInt64 { (try FileManager.default.attributesOfItem(atPath: url.path))[.systemFileNumber] as! UInt64 }
        #expect(try inode(copy.appending(path: "a/Assets.car")) == inode(copy.appending(path: "b/Assets.car")))
        #expect(try inode(copy.appending(path: "a/Assets.car")) != inode(source.appending(path: "a/Assets.car")))
        #expect(try String(contentsOf: copy.appending(path: "b/Assets.car"), encoding: .utf8) == "car")
    }

    @Test func leftoversAreStagedCopiesBesideTheAppAndWorkFoldersInTheBase() throws {
        let directory = try temporary()
        defer { clean(directory) }
        let base = directory.appending(path: "tmp", directoryHint: .isDirectory)
        let apps = directory.appending(path: "apps", directoryHint: .isDirectory)
        for folder in ["tmp/PureMouse-update-AAA", "tmp/other", "apps/.PureMouse-update-1234abcd", "apps/PureMouse.app", "apps/.hidden"] {
            try FileManager.default.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        var files = LiveUpdateFiles()
        files.base = base
        let found = files.leftovers(besides: apps.appending(path: "PureMouse.app")).map(\.lastPathComponent).sorted()
        #expect(found == [".PureMouse-update-1234abcd", "PureMouse-update-AAA"])
        let work = try files.makeWorkDirectory()
        #expect(work.deletingLastPathComponent().resolvingSymlinksInPath().path == base.resolvingSymlinksInPath().path)
    }
}
