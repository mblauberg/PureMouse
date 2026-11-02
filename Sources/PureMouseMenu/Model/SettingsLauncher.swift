import AppKit
import PureMouseAppSupport

/// Opens Settings, which is an app of its own (`PureMouse Settings.app`, docs/adr/0009): the pane
/// goes in the `show-settings` file and the doorbell rings for a helper already running, then the
/// helper is opened, which starts it or brings it forward. Where it is: `SettingsLookup`.
@MainActor
enum SettingsLauncher {
    /// A development build's bare helper binary, kept while it runs: without a bundle identifier
    /// nothing else stops a second copy.
    private static var binary: Process?

    /// `done` runs once the helper is open or the alert saying why not is answered.
    static func open(pane: SettingsPane? = nil, then done: @escaping @MainActor () -> Void = {}) {
        ShowRequest.post(pane: pane)
        switch lookup() {
        case .success(.app(let app)):
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: SettingsLookup.bundleIdentifier)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.environment = SettingsLookup.environment(from: ProcessInfo.processInfo.environment)
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error { Alerts.show("PureMouse Settings could not open", error.localizedDescription) }
                    done()
                }
            }
        case .success(.binary(let url)):
            // A running copy has already heard the doorbell.
            if binary?.isRunning != true {
                let process = Process()
                process.executableURL = url
                do {
                    try process.run()
                    binary = process
                } catch {
                    Alerts.show("PureMouse Settings could not open", "\(url.path): \(error.localizedDescription)")
                }
            }
            done()
        case .failure(let failure):
            Alerts.show("PureMouse Settings could not be found", failure.description)
            done()
        }
    }

    /// Quits the helper, which saves its edits and cancels a select by pressing as it goes. Only
    /// this app's own helper: a development copy never quits an installed one.
    static func quit() {
        switch lookup() {
        case .success(.app(let app)):
            NSRunningApplication.runningApplications(withBundleIdentifier: SettingsLookup.bundleIdentifier)
                .filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
                .forEach { $0.terminate() }
        case .success(.binary), .failure:
            binary?.terminate() // SIGTERM, which the helper turns into a normal quit
        }
    }

    private static func lookup() -> Result<SettingsLookup.Helper, SettingsLookup.Failure> {
        SettingsLookup.find(environment: ProcessInfo.processInfo.environment, bundle: Bundle.main.bundleURL,
                            executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                            exists: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
