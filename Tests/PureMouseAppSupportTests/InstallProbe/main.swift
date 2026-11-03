// Runs the real update pipeline against a release made on disk; test-only, never bundled. Driven by
// scripts/test-update-install.sh, which signs this binary with the identity of the "installed" app
// (identifier io.github.mblauberg.puremouse.menu), so the requirement it derives from itself is the
// one a real menu bar app would. Only the download is replaced: it copies from a folder instead of
// asking GitHub. The hash, the mount, the signature checks and the swap are the shipping ones.
//
//   InstallProbe <release folder> <installed app> <running version> <release version>
//   InstallProbe requirement
//
// Prints one line: "installed X", or "failed <case> | <reason> | opens-release-page=<bool>". It logs
// "download <name>" to stderr for each file it is asked for, so a test can see that none was.
import Foundation
@testable import PureMouseAppSupport

struct FolderDownloader: UpdateDownloading {
    let folder: URL
    func download(_ url: URL, to file: URL, limit: Int) async throws {
        FileHandle.standardError.write(Data("download \(url.lastPathComponent)\n".utf8))
        try FileManager.default.copyItem(at: folder.appending(path: url.lastPathComponent), to: file)
    }
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "requirement" {
    print(CodeSignatureChecker().requirement() ?? "none")
    exit(0)
}
guard arguments.count == 5, let version = UpdateCheck.Version(arguments[4]) else {
    FileHandle.standardError.write(Data("usage: InstallProbe <release folder> <installed app> <running version> <release version>\n".utf8))
    exit(64)
}
let release = UpdateCheck.Release(
    version: version, page: URL(string: "https://github.com/mblauberg/PureMouse/releases/tag/v\(arguments[4])")!)
let live = UpdateInstaller.live
let installer = UpdateInstaller(
    downloader: FolderDownloader(folder: URL(filePath: arguments[1], directoryHint: .isDirectory)),
    hasher: live.hasher, mounter: live.mounter, signature: live.signature, files: live.files,
    log: { FileHandle.standardError.write(Data(("log: " + $0 + "\n").utf8)) })

switch await installer.install(release, current: arguments[3], installedApp: URL(filePath: arguments[2], directoryHint: .isDirectory)) {
case .installed(let installed):
    print("installed \(installed.text)")
case .failed(let failure):
    print("failed \(failure) | \(failure.reason) | opens-release-page=\(failure.opensReleasePage)")
    exit(1)
}
