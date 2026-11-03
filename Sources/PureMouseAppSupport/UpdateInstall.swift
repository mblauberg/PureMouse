import Foundation

/// Why an update was not installed. Every case leaves the installed app untouched, and the one
/// line (`reason`) is what the menu and About say, with a link to the release page.
public enum UpdateInstallFailure: Error, Equatable, Sendable {
    /// This copy cannot be replaced by PureMouse, or cannot tell a genuine update from another: the
    /// release page is opened instead of downloading anything.
    public enum Place: Equatable, Sendable {
        case notInstalled, developmentBuild, readOnlyVolume, notWritable, notSigned
    }

    case cannotInstallHere(Place)
    case downloadFailed
    case checksumMissing
    case checksumMismatch
    case imageUnreadable
    case imageContents
    case unsigned
    case wrongCertificate
    case modified
    case notNewer
    /// A newer version, but not the one the release page announced.
    case notTheRelease
    case installFailed

    /// One line, naming what failed. What to do next is the release page beside it.
    public var reason: String {
        switch self {
        case .cannotInstallHere(.notInstalled): "Can't update: this isn't an installed copy"
        case .cannotInstallHere(.developmentBuild): "Can't update: this is a development build"
        case .cannotInstallHere(.readOnlyVolume): "Can't update: this copy is on a read-only disk"
        case .cannotInstallHere(.notWritable): "Can't update: this copy needs an administrator"
        case .cannotInstallHere(.notSigned): "Can't update: this copy has no certificate to check with"
        case .downloadFailed: "Couldn't download the update"
        case .checksumMissing: "The release has no checksum for the download"
        case .checksumMismatch: "The download doesn't match its checksum"
        case .imageUnreadable: "Couldn't open the downloaded disk image"
        case .imageContents: "The disk image doesn't hold exactly one PureMouse app"
        case .unsigned: "The update isn't signed"
        case .wrongCertificate: "The update wasn't signed by the same certificate"
        case .modified: "The update's files don't match its signature"
        case .notNewer: "The update isn't newer than this version"
        case .notTheRelease: "The update isn't the release that was announced"
        case .installFailed: "Couldn't replace PureMouse"
        }
    }

    /// PureMouse opens the release page itself, since it cannot install here.
    public var opensReleasePage: Bool {
        if case .cannotInstallHere = self { return true }
        return false
    }
}

public enum UpdateInstallOutcome: Equatable, Sendable {
    /// The app on disk is the new version. Relaunching is the caller's.
    case installed(UpdateCheck.Version)
    case failed(UpdateInstallFailure)
}

/// What the signature check found wrong with a bundle.
public enum UpdateSignatureFault: Equatable, Sendable {
    /// No signature at all.
    case unsigned
    /// A valid signature that does not satisfy the requirement: another certificate.
    case wrongCertificate
    /// A signature that no longer matches the files.
    case modified
}

// MARK: Seams

/// A download passed its cap.
public struct DownloadTooLarge: Error, Equatable, Sendable {}

/// Fetches a release asset into a file; throws unless it was answered with 200, and throws
/// `DownloadTooLarge`, deleting what it had written, as soon as more than `limit` bytes are promised
/// or have arrived.
public protocol UpdateDownloading: Sendable {
    func download(_ url: URL, to file: URL, limit: Int) async throws
}

/// `hdiutil attach -nobrowse -readonly` and `detach`.
public protocol ImageMounting: Sendable {
    func attach(_ image: URL, at mountPoint: URL) async throws
    /// Best effort, forced if need be; harmless when nothing is mounted there.
    func detach(_ mountPoint: URL) async
}

/// The code-signing check. The requirement comes from the running process and nowhere else.
public protocol UpdateSignatureChecking: Sendable {
    /// What a genuine update must satisfy: the running app's designated requirement, for the
    /// app's own bundle. nil when this copy has no certificate to pin.
    func requirement() -> String?
    /// nil when `bundle` is validly signed and satisfies `requirement`.
    func check(_ bundle: URL, against requirement: String) -> UpdateSignatureFault?
    /// nil when the disk image at `image` is validly signed by the certificate `requirement` pins. A
    /// disk image's identifier is its own file name, so only the certificate part of the requirement
    /// applies.
    func checkImage(_ image: URL, against requirement: String) -> UpdateSignatureFault?
}

/// Whether PureMouse can replace the installed app without asking anyone for anything.
public enum UpdateReplaceability: Equatable, Sendable {
    case ok, readOnlyVolume, notWritable
}

/// A top-level entry of a mounted image.
public struct UpdateEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, symlink, other }
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// The file system, as the installer uses it.
public protocol UpdateFiles: Sendable {
    /// A new, empty, private directory: the download location.
    func makeWorkDirectory() throws -> URL
    func makeDirectory(_ url: URL) throws
    func size(of file: URL) -> Int?
    func contents(of file: URL) throws -> Data
    func entries(of directory: URL) throws -> [UpdateEntry]
    /// `CFBundleShortVersionString` of the bundle at `url`.
    func bundleVersion(_ bundle: URL) -> String?
    func replaceability(of app: URL) -> UpdateReplaceability
    /// A copy that keeps the bundle as it is, hard links included (`ditto`), and no quarantine flag.
    func copy(_ source: URL, to destination: URL) async throws
    /// `FileManager.replaceItemAt`: one swap. It can throw after the new app is in place, leaving the
    /// old one at `staged`, so a throw says nothing about which is where.
    func replace(_ installed: URL, with staged: URL) throws
    func remove(_ url: URL)
    /// What an install that was killed leaves: staged copies beside `app` and work folders.
    func leftovers(besides app: URL) -> [URL]
}

public typealias UpdateHasher = @Sendable (URL) throws -> String

// MARK: The pipeline

/// Installs a release from the menu, verified by the running app's own code signature
/// (docs/adr/0022-update-trust-is-the-signing-requirement.md).
///
/// In order, stopping at the first failure with the installed app untouched: the disk image's
/// SHA-256 against the release's `SHA256SUMS`; the image's own signature, by the certificate of the
/// running process; the image mounted read-only, holding exactly one `PureMouse.app`; that bundle's
/// signature, validated against the requirement of the running process; a version newer than the
/// running one and equal to the release's. Then the bundle is copied next to the installed app and
/// swapped in with one `replaceItemAt`; if that throws, the disk says which app is installed. The
/// image is unmounted and the download deleted however it ends.
///
/// Everything it touches is injected, so the tests give it fixtures. This runs in the menu bar app
/// or the Settings helper, never in `puremouse` or PureMouseKit.
public struct UpdateInstaller: Sendable {
    public var downloader: any UpdateDownloading
    public var hasher: UpdateHasher
    public var mounter: any ImageMounting
    public var signature: any UpdateSignatureChecking
    public var files: any UpdateFiles
    /// Where the detail goes (the unified log), since the one line says only what failed.
    public var log: @Sendable (String) -> Void

    public init(downloader: any UpdateDownloading, hasher: @escaping UpdateHasher, mounter: any ImageMounting,
                signature: any UpdateSignatureChecking, files: any UpdateFiles,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.downloader = downloader
        self.hasher = hasher
        self.mounter = mounter
        self.signature = signature
        self.files = files
        self.log = log
    }

    /// The disk image is about 5 MB and the checksum file a few hundred bytes.
    static let maxImageBytes = 64_000_000
    static let maxChecksumBytes = 65_536
    public static let appName = "PureMouse.app"

    /// `current`: the running version. `installedApp`: the app bundle to replace, nil when this
    /// process is not inside an installed one.
    public func install(_ release: UpdateCheck.Release, current: String, installedApp: URL?) async -> UpdateInstallOutcome {
        // Before anything is downloaded: can this copy be replaced, and checked against?
        guard let installedApp else { return .failed(.cannotInstallHere(.notInstalled)) }
        guard let running = UpdateCheck.Version(current) else { return .failed(.cannotInstallHere(.developmentBuild)) }
        switch files.replaceability(of: installedApp) {
        case .ok: break
        case .readOnlyVolume: return .failed(.cannotInstallHere(.readOnlyVolume))
        case .notWritable: return .failed(.cannotInstallHere(.notWritable))
        }
        guard let requirement = signature.requirement() else { return .failed(.cannotInstallHere(.notSigned)) }
        guard let assets = UpdateAssets(release) else { return .failed(.downloadFailed) }
        await sweep(besides: installedApp)
        let work: URL
        do { work = try files.makeWorkDirectory() } catch {
            log("update: no download location: \(error)")
            return .failed(.downloadFailed)
        }

        var mountPoint: URL?
        var staged: URL?
        /// Leaves nothing behind: the image detached, the staged copy and the download deleted.
        func finish(_ outcome: UpdateInstallOutcome) async -> UpdateInstallOutcome {
            if let mountPoint { await mounter.detach(mountPoint) }
            if let staged { files.remove(staged) }
            files.remove(work)
            if case .failed(let failure) = outcome { log("update: not installed: \(failure.reason)") }
            return outcome
        }

        // 1. The image's SHA-256 matches its line in SHA256SUMS.
        let sums = work.appending(path: "SHA256SUMS")
        let image = work.appending(path: assets.imageName)
        do {
            try await downloader.download(assets.sums, to: sums, limit: Self.maxChecksumBytes)
            guard let sumsSize = files.size(of: sums), sumsSize <= Self.maxChecksumBytes else {
                return await finish(.failed(.downloadFailed))
            }
            try await downloader.download(assets.image, to: image, limit: Self.maxImageBytes)
            guard let imageSize = files.size(of: image), imageSize > 0, imageSize <= Self.maxImageBytes else {
                return await finish(.failed(.downloadFailed))
            }
        } catch {
            log("update: download failed: \(error)")
            return await finish(.failed(.downloadFailed))
        }
        let expected: String?
        do { expected = Checksums.hash(for: assets.imageName, in: try files.contents(of: sums)) } catch {
            return await finish(.failed(.checksumMissing))
        }
        guard let expected else { return await finish(.failed(.checksumMissing)) }
        let actual: String
        do { actual = try hasher(image) } catch {
            log("update: could not hash the download: \(error)")
            return await finish(.failed(.downloadFailed))
        }
        guard actual == expected else { return await finish(.failed(.checksumMismatch)) }

        // 2. The image is signed by the certificate the running app is, before anything parses it.
        if let fault = signature.checkImage(image, against: requirement) { return await finish(.failed(Self.failure(fault))) }

        // 3. Mounted read-only and out of the Finder's sight, it holds exactly one PureMouse.app.
        let mount = work.appending(path: "image")
        mountPoint = mount
        do {
            try files.makeDirectory(mount)
            try await mounter.attach(image, at: mount)
        } catch {
            log("update: could not mount the image: \(error)")
            return await finish(.failed(.imageUnreadable))
        }
        let bundle: URL
        do {
            let apps = try files.entries(of: mount).filter { $0.name.lowercased().hasSuffix(".app") }
            guard apps.count == 1, let app = apps.first, app.name == Self.appName, app.kind == .directory else {
                return await finish(.failed(.imageContents))
            }
            bundle = mount.appending(path: app.name)
        } catch {
            log("update: could not read the image: \(error)")
            return await finish(.failed(.imageUnreadable))
        }

        // 4. Its signature satisfies the running app's requirement.
        if let fault = signature.check(bundle, against: requirement) { return await finish(.failed(Self.failure(fault))) }

        // 5. It is newer than this version, and is the version the release announced.
        guard let found = files.bundleVersion(bundle).flatMap(UpdateCheck.Version.init), found > running else {
            return await finish(.failed(.notNewer))
        }
        guard found == release.version else { return await finish(.failed(.notTheRelease)) }

        // Copy it next to the installed app, so the swap is one rename on one volume, check the copy
        // as well, and swap.
        let copy = installedApp.deletingLastPathComponent().appending(path: ".PureMouse-update-\(UUID().uuidString.prefix(8))")
        staged = copy
        do {
            try await files.copy(bundle, to: copy)
        } catch {
            log("update: could not copy the update: \(error)")
            return await finish(.failed(.installFailed))
        }
        if let fault = signature.check(copy, against: requirement) { return await finish(.failed(Self.failure(fault))) }
        guard files.bundleVersion(copy).flatMap(UpdateCheck.Version.init) == found else { return await finish(.failed(.modified)) }
        do {
            try files.replace(installedApp, with: copy)
            staged = nil
        } catch {
            // The swap can throw after the new app is in place, with the old one left at the staged
            // path. What is where is read from the disk, and nothing that might be the only good
            // copy is deleted.
            log("update: the replace threw: \(error)")
            switch settle(installedApp, running: running, found: found, requirement: requirement) {
            case .new:
                log("update: the new app is in place; the old copy is left over")
            case .old:
                return await finish(.failed(.installFailed))
            case .unknown:
                log("update: can't tell which copy is installed; keeping \(copy.path)")
                staged = nil
                return await finish(.failed(.installFailed))
            }
        }
        return await finish(.installed(found))
    }

    enum Settled { case new, old, unknown }

    /// Which app is at the install path after a replace that threw. `.new` only for the announced
    /// version with a signature that satisfies the requirement; `.old` for the version that was
    /// running (the staged copy is then the new one, which a download brings back).
    func settle(_ installedApp: URL, running: UpdateCheck.Version, found: UpdateCheck.Version, requirement: String) -> Settled {
        guard let version = files.bundleVersion(installedApp).flatMap(UpdateCheck.Version.init) else { return .unknown }
        if version == found, signature.check(installedApp, against: requirement) == nil { return .new }
        if version == running { return .old }
        return .unknown
    }

    /// What a killed install left: staged copies beside the app, and work folders (with an image
    /// possibly still mounted in one). Only the installed app exists to be lost, and it is known to be
    /// there, so none of this is the only good copy.
    func sweep(besides installedApp: URL) async {
        for stale in files.leftovers(besides: installedApp) {
            if stale.lastPathComponent.hasPrefix("PureMouse-update-") {
                await mounter.detach(stale.appending(path: "image"))
            }
            log("update: removing what an earlier install left: \(stale.lastPathComponent)")
            files.remove(stale)
        }
    }

    static func failure(_ fault: UpdateSignatureFault) -> UpdateInstallFailure {
        switch fault {
        case .unsigned: .unsigned
        case .wrongCertificate: .wrongCertificate
        case .modified: .modified
        }
    }
}

/// The two files a release carries that an install needs, found from the release page #126 found:
/// `https://github.com/mblauberg/PureMouse/releases/tag/vX.Y.Z` has its assets at
/// `.../releases/download/vX.Y.Z/PureMouse-X.Y.Z.dmg` and `SHA256SUMS` (`scripts/release.sh`).
struct UpdateAssets: Equatable {
    let image: URL
    let sums: URL
    let imageName: String

    init?(_ release: UpdateCheck.Release) {
        let components = release.page.pathComponents
        guard UpdateCheck.isReleasePage(release.page), components.count == 6, components[4] == "tag" else { return nil }
        let tag = components[5]
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let first = version.first, first.isASCII, first.isNumber,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              let base = URL(string: "https://github.com/mblauberg/PureMouse/releases/download/\(tag)/") else { return nil }
        imageName = "PureMouse-\(version).dmg"
        image = base.appending(path: imageName)
        sums = base.appending(path: "SHA256SUMS")
    }
}

/// `shasum -a 256 PureMouse-X.Y.Z.dmg > SHA256SUMS`: lines of a hash, whitespace and a file name
/// (`*` before it for a binary-mode line).
enum Checksums {
    /// The lowercase hash on the line for exactly `name`; nil when there is none, when there are
    /// two that disagree, or when the hash is not 64 hex digits.
    static func hash(for name: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        var found: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard parts.count == 2 else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard file == name else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
            found.insert(hash)
        }
        return found.count == 1 ? found.first : nil
    }
}
