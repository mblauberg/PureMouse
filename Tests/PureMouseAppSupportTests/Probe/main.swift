// A second writer process for ConcurrentWritersTests; test-only, never bundled.
//
//   ConfigWriterProbe <dir> save <prefix> <count> [reset-after]
//       saves <prefix>.k0 … k<count-1> to <dir>/config.json one at a time, replacing the file
//       once (keeping a backup) after save number <reset-after>
//   ConfigWriterProbe <dir> control <menu|settings> <count>
//       writes control.json <count> times as that role: the menu toggles `paused` (ending
//       paused), Settings starts and cancels captures (ending with token 77 open)
import Foundation
import PureMouseAppSupport
import PureMouseKit

let arguments = CommandLine.arguments
guard arguments.count >= 5, let count = Int(arguments[4]) else {
    FileHandle.standardError.write(Data("usage: ConfigWriterProbe <dir> save|control …\n".utf8))
    exit(64)
}
let directory = URL(filePath: arguments[1], directoryHint: .isDirectory)
let locations = Locations(config: directory.appending(path: "config.json"), log: directory.appending(path: "log"),
                          daemon: nil, companion: directory.appending(path: "companion", directoryHint: .isDirectory))

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch arguments[2] {
case "save":
    let prefix = arguments[3]
    let resetAfter = arguments.count > 5 ? Int(arguments[5]) : nil
    let file = ConfigFile(url: locations.config)
    for index in 0..<count {
        do {
            _ = try file.save([ConfigTree.Change(path: [prefix, "k\(index)"], value: index)])
        } catch {
            fail("save \(prefix).k\(index): \(error)")
        }
        if index == resetAfter {
            do { try file.replace(with: ConfigTree().data(), keepingBackup: true) } catch { fail("reset: \(error)") }
        }
    }
case "control":
    MainActor.assumeIsolated {
        let menu = arguments[3] == "menu"
        let link = DaemonLink(locations: locations, ring: {})
        link.controlFailed = { fail("control: \($0)") }
        for index in 0..<count {
            if menu {
                link.setPaused(index % 2 == 0 || index == count - 1)
            } else if index == count - 1 || index % 2 == 0 {
                let token = index == count - 1 ? 77 : 1000 + index
                link.writeControl { $0.capture = Control.Capture(token: token) }
            } else {
                // Cancel the capture started just before, unless the file now holds another.
                link.writeControl { if $0.capture?.token == 1000 + index - 1 { $0.capture = nil } }
            }
        }
    }
default:
    fail("unknown command \(arguments[2])")
}
