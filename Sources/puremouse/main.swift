import Foundation
import HIDPP

setvbuf(stdout, nil, _IOLBF, 0)

/// Serves the main queue on the main thread until exit. `dispatchMain()` would park the main thread
/// and drain the queue on another, which macOS 26 and earlier reject in `MainActor.assumeIsolated`.
func runMainLoop() -> Never {
    while true { CFRunLoopRun() }
}

// Older macOS passes a process serial number to apps opened from the Finder.
var arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if let i = arguments.firstIndex(of: "--verbose") {
    Log.verbose = true
    arguments.remove(at: i)
}

switch arguments.first {
case nil where LoginItem.inBundle:
    // Opened from the Finder: install the login agent, which runs the daemon.
    do {
        LoginItem.alert("PureMouse", try LoginItem.register() + """


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
    let url = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : Config.defaultURL
    let config: Config
    do {
        config = try Config.load(from: url)
    } catch {
        // Stay up with nothing configured rather than crash-loop under launchd; fixing the
        // file and sending SIGHUP picks it up.
        Log.error("cannot load \(url.path): \(error); running unconfigured until reload")
        config = .empty
    }
    // Private interfaces (Dock notifications, swipe event fields) can change between releases,
    // so record which macOS each log belongs to.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    Log.info("PureMouse \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let daemon = Daemon(config: config, configURL: url)
    daemon.start()
    withExtendedLifetime(daemon) { runMainLoop() }
case "permissions":
    // The exit status is the granted set's raw value; the daemon polls it (Daemon.restartWhenGranted).
    let granted = Permissions.current
    print("Accessibility: \(granted.contains(.accessibility) ? "granted" : "missing")")
    print("Input Monitoring: \(granted.contains(.inputMonitoring) ? "granted" : "missing")")
    exit(granted.rawValue)
case "action" where arguments.count == 2:
    // Fires one action as a button would, to check it still works (e.g. after a macOS upgrade).
    let spec = arguments[1]
    let json = spec.hasPrefix("{") ? spec : "\"\(spec)\""
    guard let action = try? JSONDecoder().decode(Action.self, from: Data(json.utf8)),
          action != .toggleScrollMode else {
        print("unknown or device-only action: \(spec)")
        exit(64)
    }
    Task { @MainActor in
        SystemActions.perform(action)
        try? await Task.sleep(for: .milliseconds(200))  // let posted events drain
        exit(0)
    }
    runMainLoop()
case "register":
    do {
        print(try LoginItem.register())
    } catch {
        print("cannot register: \(error)")
        exit(1)
    }
case "unregister":
    do {
        try LoginItem.unregister()
    } catch {
        print("cannot unregister: \(error)")
        exit(1)
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
    print("""
    usage: puremouse [--verbose] [run [config.json]]   run the daemon (default config:
                                                      ~/.config/puremouse/config.json); inside
                                                      the app, bare `puremouse` registers it
           puremouse probe                            read-only dump of connected HID++ devices
           puremouse permissions                      macOS permissions of the launching process
           puremouse action <name | {"keys": ...}>    perform one action now, as a button would
           puremouse register | unregister            start (or restart) or stop the installed
                                                      app's login agent; unregister also stops
                                                      it at login
    Send SIGHUP to reload the config.
    """)
    exit(64)
}
