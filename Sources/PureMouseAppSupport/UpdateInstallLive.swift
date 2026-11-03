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

/// One GET in an ephemeral session, as the update check makes: no cookies, no cache. The body is
/// written to the file as it arrives and stops at `limit`: a response that promises more is refused
/// before a byte is read, and one that goes past it is cancelled and its partial file deleted.
struct EphemeralDownloader: UpdateDownloading {
    /// Extra `URLProtocol` classes, for the tests; empty when live.
    var protocols: [AnyClass] = []

    func download(_ url: URL, to file: URL, limit: Int) async throws {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        if !protocols.isEmpty { configuration.protocolClasses = protocols + (configuration.protocolClasses ?? []) }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Int64(limit) else { throw DownloadTooLarge() }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var total = 0
            var chunk = Data()
            chunk.reserveCapacity(1 << 16)
            for try await byte in bytes {
                chunk.append(byte)
                guard chunk.count >= 1 << 16 else { continue }
                total += chunk.count
                guard total <= limit else { throw DownloadTooLarge() }
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            total += chunk.count
            guard total <= limit else { throw DownloadTooLarge() }
            try handle.write(contentsOf: chunk)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
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
    /// The certificate half of a requirement `forApp` made, which is all a disk image can be held
    /// to: its identifier is its file name. nil for any other text.
    public static func certificate(of requirement: String) -> String? {
        let prefix = "identifier \"\(appIdentifier)\" and "
        guard requirement.hasPrefix(prefix) else { return nil }
        let pin = String(requirement.dropFirst(prefix.count))
        return pin.hasPrefix("(") && pin.hasSuffix(")") ? pin : nil
    }

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
        check(bundle, against: requirement, flags: Self.flags)
    }

    private func check(_ bundle: URL, against requirement: String, flags: SecCSFlags) -> UpdateSignatureFault? {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            return .wrongCertificate
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        return Self.fault(SecStaticCodeCheckValidity(code, flags, parsed))
    }

    public func checkImage(_ image: URL, against requirement: String) -> UpdateSignatureFault? {
        guard let certificate = SigningRequirement.certificate(of: requirement) else { return .wrongCertificate }
        return check(image, against: certificate, flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate))
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
    /// Where work folders go: the user's temporary directory, or a test's own.
    var base = FileManager.default.temporaryDirectory

    func makeWorkDirectory() throws -> URL {
        let directory = base.appending(path: "PureMouse-update-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// `ditto` and not `copyItem`, which gives each of the bundle's hard links (the nested apps'
    /// `Assets.car`) a copy of its own. Nothing in the image is quarantined, since the download
    /// never was (`scripts/test-update-install.sh` checks the installed copy for the flag).
    func copy(_ source: URL, to destination: URL) async throws {
        try await runTool("/usr/bin/ditto", [source.path, destination.path])
    }

    func replace(_ installed: URL, with staged: URL) throws {
        _ = try manager.replaceItemAt(installed, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
    }

    func leftovers(besides app: URL) -> [URL] {
        func list(_ directory: URL, prefix: String) -> [URL] {
            ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        return list(app.deletingLastPathComponent(), prefix: ".PureMouse-update-") + list(base, prefix: "PureMouse-update-")
    }

    /// Best effort. What is left to remove can be the old app after a swap that threw, and a resource
    /// in it that is flagged immutable or carries a deny-delete ACL is what made the swap throw: the
    /// flags and ACLs are cleared, as the owner could, and the removal tried again.
    func remove(_ url: URL) {
        if (try? manager.removeItem(at: url)) != nil { return }
        guard (try? manager.attributesOfItem(atPath: url.path)) != nil else { return }
        if let walk = manager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in walk { try? manager.setAttributes([.immutable: false], ofItemAtPath: item.path) }
        }
        try? manager.setAttributes([.immutable: false], ofItemAtPath: url.path)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "-N", url.path]
        chmod.standardOutput = FileHandle.nullDevice
        chmod.standardError = FileHandle.nullDevice
        if (try? chmod.run()) != nil { chmod.waitUntilExit() }
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
