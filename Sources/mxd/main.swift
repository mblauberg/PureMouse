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
    let daemon = Daemon(config: config, configURL: url)
    daemon.start()
    withExtendedLifetime(daemon) { dispatchMain() }
case "permissions":
    // The exit status is the granted set's raw value; the daemon polls it (Daemon.restartWhenGranted).
    let granted = Permissions.current
    print("Accessibility: \(granted.contains(.accessibility) ? "granted" : "missing")")
    print("Input Monitoring: \(granted.contains(.inputMonitoring) ? "granted" : "missing")")
    exit(granted.rawValue)
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
    Send SIGHUP to reload the config.
    """)
    exit(64)
}
