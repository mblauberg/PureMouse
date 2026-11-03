import AppKit
import PureMouseAppSupport
import UniformTypeIdentifiers

/// Export Settings… and Import Settings…: General › Advanced… and the File menu both call these.
/// Standard save and open panels, and a system alert to confirm. Import never asks a device for
/// anything (`ConfigTransfer`).
@MainActor
public enum ConfigTransferActions {
    public enum ImportOutcome: Equatable {
        case replaced
        case cancelled
        /// The file was refused (it did not validate, naming the field) or could not be written.
        case refused(String)
    }

    // MARK: Panels

    public static func exportSettings(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ConfigTransfer.exportName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Save a copy of your PureMouse settings."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = model.exportSettings(to: url) { Alerts.show("Settings weren't exported.", problem) }
    }

    public static func importSettings(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a PureMouse settings file. It replaces all your settings."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if case .refused(let problem) = importSettings(model, from: url, confirm: { askToReplace($0, model) }) {
            Alerts.show("Can't import \(url.lastPathComponent).", problem)
        }
    }

    // MARK: Steps

    /// Reads and validates `url`, asks `confirm`, and replaces the config when it says yes. The
    /// panels and the dev hooks (`PUREMOUSE_DEV_IMPORT`) differ only in who answers.
    public static func importSettings(_ model: AppModel, from url: URL,
                                      confirm: (ConfigTransfer.Candidate) -> Bool) -> ImportOutcome {
        let candidate: ConfigTransfer.Candidate
        do {
            candidate = try ConfigTransfer.read(url)
        } catch {
            return .refused((error as? ConfigTransfer.Refusal)?.message ?? error.localizedDescription)
        }
        guard confirm(candidate) else { return .cancelled }
        if let problem = model.importSettings(candidate) { return .refused(problem) }
        return .replaced
    }

    /// "Replace all settings?", with the count of `run` commands the file holds, if any. Replace is
    /// the default button; Cancel answers Esc.
    private static func askToReplace(_ candidate: ConfigTransfer.Candidate, _ model: AppModel) -> Bool {
        let text = ConfigTransfer.confirmation(for: candidate, backupName: model.backupName)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

#if DEBUG
/// Development only, for driving Export and Import over SSH where nobody can answer a panel:
/// `PUREMOUSE_DEV_EXPORT=<path>` exports the config to that file; `PUREMOUSE_DEV_IMPORT=<path>`
/// imports that file as if Replace was chosen, or Cancel with `PUREMOUSE_DEV_IMPORT_CANCEL=1`.
/// The outcome goes to stderr (`export: ok`, `export: failed: …`, `import: replaced`,
/// `import: cancelled`, `import: refused: …`) and the app quits. Run it against copies
/// (`PUREMOUSE_CONFIG`, `PUREMOUSE_DAEMON` and `PUREMOUSE_COMPANION_DIR`).
@MainActor
public enum DevTransfer {
    /// Whether a hook asked for a transfer; the caller quits once it is done.
    public static func run(_ model: AppModel, environment: [String: String] = ProcessInfo.processInfo.environment,
                           report: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Bool {
        var asked = false
        if let path = environment["PUREMOUSE_DEV_EXPORT"] {
            asked = true
            report(model.exportSettings(to: URL(fileURLWithPath: path)).map { "export: failed: \($0)" } ?? "export: ok")
        }
        if let path = environment["PUREMOUSE_DEV_IMPORT"] {
            asked = true
            let cancel = environment["PUREMOUSE_DEV_IMPORT_CANCEL"] != nil
            switch ConfigTransferActions.importSettings(model, from: URL(fileURLWithPath: path), confirm: { _ in !cancel }) {
            case .replaced: report("import: replaced")
            case .cancelled: report("import: cancelled")
            case .refused(let problem): report("import: refused: \(problem)")
            }
        }
        return asked
    }
}
#endif
