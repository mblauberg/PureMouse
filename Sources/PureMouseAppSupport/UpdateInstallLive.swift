import CommonCrypto
import Foundation
import Security

// The live parts of `UpdateInstaller`: the network, `hdiutil`, Security.framework and the file
// system. None of this is in `puremouse` or PureMouseKit; it runs in the menu bar app or the
// Settings helper (docs/adr/0022-update-trust-is-the-signing-requirement.md).

extension UpdateInstaller {
    public static var live: UpdateInstaller {
        UpdateInstaller(downloader: EphemeralDownloader(), hasher: Sha256.hex(of:), mounter: HdiutilMounter(),
                        signature: CodeSignatureChecker(), files: LiveUpdateFiles(),
                        log: { NSLog("PureMouse: %@", $0) })
    }
}

/// One GET in an ephemeral session, as the update check makes: no cookies, no cache. The body goes
/// straight to a file.
struct EphemeralDownloader: UpdateDownloading {
    func download(_ url: URL, to file: URL) async throws {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.moveItem(at: temporary, to: file)
    }
}

enum Sha256 {
    /// The lowercase hex SHA-256 of a file, read a megabyte at a time.
    static func hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ProcessFailure: Error, CustomStringConvertible {
    var tool: String
    var status: Int32
    var description: String { "\(tool) exited \(status)" }
}

/// Runs a tool to completion without blocking a thread; its output is discarded.
func runTool(_ path: String, _ arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus == 0 {
                continuation.resume()
            } else {
                continuation.resume(throwing: ProcessFailure(tool: path, status: process.terminationStatus))
            }
        }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}

/// `hdiutil attach -nobrowse -readonly`: out of the Finder's sight, never writable. The image's
/// own checksum is skipped (`-noverify`) since its SHA-256 has been checked already.
struct HdiutilMounter: ImageMounting {
    func attach(_ image: URL, at mountPoint: URL) async throws {
        try await runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                               "-mountpoint", mountPoint.path, image.path])
    }

    func detach(_ mountPoint: URL) async {
        if (try? await runTool("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])) != nil { return }
        try? await runTool("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
    }
}

// MARK: Signature

/// What a genuine update must satisfy, derived from the running app's own designated requirement.
public enum SigningRequirement {
    /// The identifier of PureMouse.app, which a release's top-level bundle carries (frozen:
    /// `scripts/lib.zsh`).
    public static let appIdentifier = "io.github.mblauberg.puremouse"

    /// The running process may be a nested bundle (the menu bar app, the Settings helper), whose
    /// designated requirement is `identifier "<its own>" and <certificate pin>`. A release is checked
    /// as the app, so the pin is kept and the identifier is the app's. Only the two shapes this
    /// project's signing produces are accepted: a leaf-certificate hash (the self-signed
    /// identity), or Apple's chain for a named team (Developer ID). Anything else, an ad-hoc
    /// signature's `cdhash` included, has no certificate to pin and returns nil.
    public static func forApp(designated: String, runningIdentifier: String?) -> String? {
        guard let identifier = runningIdentifier, !identifier.isEmpty, !identifier.contains("\"") else { return nil }
        let prefix = "identifier \"\(identifier)\" and "
        guard designated.hasPrefix(prefix) else { return nil }
        let pin = designated.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = pin.hasPrefix("certificate leaf = H\"") && pin.hasSuffix("\"")
            && !pin.dropFirst(21).dropLast().contains("\"") && pin.dropFirst(21).dropLast().allSatisfy(\.isHexDigit)
        let team = pin.hasPrefix("anchor apple generic and ") && pin.contains("certificate leaf[subject.OU] = ")
        guard leaf || team else { return nil }
        return "identifier \"\(appIdentifier)\" and (\(pin))"
    }
}

/// `SecStaticCodeCheckValidity` against a requirement taken from the running process.
public struct CodeSignatureChecker: UpdateSignatureChecking {
    public init() {}

    /// `SecCodeCopySelf` → `SecCodeCopyDesignatedRequirement`. Never the download, never an Info.plist.
    public func requirement() -> String? {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return nil }
        return Self.requirement(of: code)
    }

    /// The requirement a release must meet, from the designated requirement of `code`.
    static func requirement(of code: SecStaticCode) -> String? {
        var designated: SecRequirement?
        var text: CFString?
        var information: CFDictionary?
        guard SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated,
              SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return SigningRequirement.forApp(designated: text as String, runningIdentifier: identifier)
    }

    static let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)

    public func check(_ bundle: URL, against requirement: String) -> UpdateSignatureFault? {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            return .wrongCertificate
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        return Self.fault(SecStaticCodeCheckValidity(code, Self.flags, parsed))
    }

    static func fault(_ status: OSStatus) -> UpdateSignatureFault? {
        switch status {
        case errSecSuccess: nil
        case errSecCSUnsigned: .unsigned
        case errSecCSReqFailed: .wrongCertificate
        default: .modified
        }
    }
}

// MARK: Files

struct LiveUpdateFiles: UpdateFiles {
    private var manager: FileManager { .default }

    func makeWorkDirectory() throws -> URL {
        let directory = manager.temporaryDirectory.appending(path: "PureMouse-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func makeDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func size(of file: URL) -> Int? {
        (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int
    }

    func contents(of file: URL) throws -> Data { try Data(contentsOf: file) }

    func entries(of directory: URL) throws -> [UpdateEntry] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]).map { url in
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let kind: UpdateEntry.Kind = values?.isSymbolicLink == true ? .symlink : values?.isDirectory == true ? .directory : .other
            return UpdateEntry(name: url.lastPathComponent, kind: kind)
        }
    }

    func bundleVersion(_ bundle: URL) -> String? {
        let plist = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// The swap renames the installed app aside and deletes it, and renames the new one in: that
    /// needs the volume writable, its folder writable, and every folder inside the app writable (an
    /// app copied by an administrator is not, and would be half deleted).
    func replaceability(of app: URL) -> UpdateReplaceability {
        let folder = app.deletingLastPathComponent()
        if (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return .readOnlyVolume }
        if app.path.contains("/AppTranslocation/") { return .readOnlyVolume }
        guard manager.isWritableFile(atPath: folder.path), manager.isWritableFile(atPath: app.path) else { return .notWritable }
        guard let walk = manager.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return .notWritable
        }
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true, !manager.isWritableFile(atPath: url.path) {
                return .notWritable
            }
        }
        return .ok
    }

    func copy(_ source: URL, to destination: URL) throws {
        try manager.copyItem(at: source, to: destination)
    }

    func replace(_ installed: URL, with staged: URL) throws {
        _ = try manager.replaceItemAt(installed, withItemAt: staged)
    }

    func remove(_ url: URL) {
        try? manager.removeItem(at: url)
    }
}

/// Opens the installed app the way double-clicking it does: `puremouse` with no arguments runs
/// `register`, which replaces the running background process and menu bar app with the new copy's
/// (`LoginItem.finderLaunch`). The same path as opening it by hand.
public enum UpdateRelaunch {
    /// Whether `open` accepted the app.
    public static func open(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [app.path]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
