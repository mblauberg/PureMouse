import Foundation
import HIDPP

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
if let i = arguments.firstIndex(of: "--verbose") {
    Log.verbose = true
    arguments.remove(at: i)
}

switch arguments.first {
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
    Log.info("mxd \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let daemon = Daemon(config: config, configURL: url)
    daemon.start()
    withExtendedLifetime(daemon) { dispatchMain() }
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
    dispatchMain()
case "probe":
    let monitor = HIDMonitor()
    monitor.start()
    Task { @MainActor in
        await Probe.run(monitor: monitor)
        exit(0)
    }
    withExtendedLifetime(monitor) { dispatchMain() }
default:
    print("""
    usage: mxd [--verbose] [run [config.json]]   run the daemon (default config: ~/.config/mxd/config.json)
           mxd probe                            read-only dump of connected HID++ devices
           mxd permissions                      macOS permissions of the launching process
           mxd action <name | {"keys": ...}>    perform one action now, as a button would
    Send SIGHUP to reload the config.
    """)
    exit(64)
}
