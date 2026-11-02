import Foundation
import PureMouseKit
import HIDPP

setvbuf(stdout, nil, _IOLBF, 0)

/// Serves the main queue on the main thread until exit. `dispatchMain()` would park the main thread
/// and drain the queue on another, which macOS 26 and earlier reject in `MainActor.assumeIsolated`.
func runMainLoop() -> Never {
    while true { CFRunLoopRun() }
}

let login = LoginItem()

// Older macOS passes a process serial number to apps opened from the Finder.
var arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if let i = arguments.firstIndex(of: "--verbose") {
    Log.verbose = true
    arguments.remove(at: i)
}

switch arguments.first {
case nil where LoginItem.inBundle:
    // Opened from the Finder: install the login agents, then show the menu bar app's Settings.
    do {
        let outcome = try login.register()
        // With the icon hidden, the app still opens for Settings and quits when they close.
        if let menu = LoginItem.menuApp, LoginItem.openMenu(menu) { exit(0) }
        LoginItem.alert("PureMouse", outcome + """


            macOS will ask for Accessibility and Input Monitoring; allow both in System Settings › \
            Privacy & Security.

            Settings: ~/.config/puremouse/config.json
            Log: ~/Library/Logs/PureMouse.log
            """)
    } catch {
        LoginItem.alert("PureMouse could not start", "\(error)")
        exit(1)
    }
case nil, "run":
    // First, so every line of this run lands in ~/Library/Logs/PureMouse.log when launchd starts
    // it (a terminal run keeps printing to the terminal).
    Log.file = LogFile.attachStderr()
    let url = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : Config.defaultURL
    // Private interfaces (Dock notifications, swipe event fields) can change between releases,
    // so record which macOS each log belongs to.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    Log.info("PureMouse \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let daemon = Daemon(configURL: url)
    daemon.start()
    withExtendedLifetime(daemon) { runMainLoop() }
case "permissions":
    // The exit status is the granted set's raw value; the daemon polls it (Daemon.pollPermissions).
    let granted = Permissions.current
    print("Accessibility: \(granted.contains(.accessibility) ? "granted" : "missing")")
    print("Input Monitoring: \(granted.contains(.inputMonitoring) ? "granted" : "missing")")
    exit(granted.rawValue)
case "action" where arguments.count == 2:
    // Fires one action as a button would, to check it still works (e.g. after a macOS upgrade).
    let spec = arguments[1]
    let json = spec.hasPrefix("{") ? spec : "\"\(spec)\""
    guard let action = try? JSONDecoder().decode(Action.self, from: Data(json.utf8)),
          !action.actsOnDevice else {
        print("unknown or device-only action: \(spec)")
        exit(64)
    }
    Task { @MainActor in
        SystemActions.perform(action)
        try? await Task.sleep(for: .milliseconds(200))  // let posted events drain
        exit(0)
    }
    runMainLoop()
case "app":
    // Which app per-app settings would use now, and how long each lookup took.
    MainActor.assumeIsolated {
        let lookup = ForegroundApp.shared
        for (label, find) in [("frontmost", lookup.frontmost), ("under pointer", lookup.underPointer)] {
            let start = ContinuousClock.now
            let app = find()
            print("\(label): \(app ?? "unknown") (\(start.duration(to: .now)))")
        }
    }
case "login-status":
    // Read-only, so it keeps the menu bar app's process group.
    do {
        print(try login.loginStatus().json())
    } catch {
        print("cannot read the login state: \(error)")
        exit(1)
    }
case "register", "unregister", "stop", "start", "login", "menu":
    // launchd kills a job's process group when booting it out, and the menu bar app (one of the
    // jobs) runs these commands as its child: leave its group so the command can finish.
    setsid()
    switch (arguments.first, arguments.dropFirst().first) {
    case ("register", _):
        do {
            print(try login.register())
        } catch {
            print("cannot register: \(error)")
            exit(1)
        }
    case ("unregister", _):
        do {
            try login.unregister()
        } catch {
            print("cannot unregister: \(error)")
            exit(1)
        }
    case ("stop", _):
        do {
            print(try login.stopAll())
        } catch {
            print("cannot stop: \(error)")
            exit(1)
        }
    case ("start", _):
        do {
            print(try login.start())
        } catch {
            print("cannot start: \(error)")
            exit(1)
        }
    case ("login", let setting?) where setting == "on" || setting == "off":
        do {
            print(try setting == "on" ? login.loginOn() : login.loginOff())
        } catch {
            print("cannot change login: \(error)")
            exit(1)
        }
    case ("menu", let setting?) where setting == "on" || setting == "off":
        do {
            print(try login.showMenu(setting == "on"))
        } catch {
            print("cannot change the menu bar icon: \(error)")
            exit(1)
        }
    default:
        usage()
    }
case "probe":
    let monitor = HIDMonitor()
    monitor.start()
    Task { @MainActor in
        await Probe.run(monitor: monitor)
        exit(0)
    }
    withExtendedLifetime(monitor) { runMainLoop() }
default:
    usage()
}

func usage() -> Never {
    print("""
    usage: puremouse [--verbose] [run [config.json]]   run the daemon (default config:
                                                      ~/.config/puremouse/config.json); inside
                                                      the app, bare `puremouse` registers it
           puremouse probe                            read-only dump of connected HID++ devices
           puremouse permissions                      macOS permissions of the launching process
           puremouse action <name | {"keys": ...}>    perform one action now, as a button would
           puremouse app                              the frontmost app and the app under the pointer,
                                                      as per-app settings see them
           puremouse register                         start (or restart) the installed app and its
                                                      menu bar icon, now and at login
           puremouse unregister                       stop both and remove them from login
           puremouse stop                             stop both until the next login
           puremouse start                            start both now, leaving login as it is
           puremouse login on | off                   start at login, or not, leaving what is
                                                      running as it is
           puremouse login-status                     whether each starts at login, as JSON
           puremouse menu on | off                    show or hide the menu bar icon
    The config is reloaded when its file changes, or on SIGHUP.
    """)
    exit(64)
}
