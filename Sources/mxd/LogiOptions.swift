import Darwin

/// Logi Options+ diverts the same buttons and wheels and rewrites the same settings, so with
/// both running the mouse flips between them. mxd cannot stop it; it only says so in the log.
enum LogiOptions {
    /// Executable-name prefixes of its agent, updater, app and plugin service. Matched
    /// case-insensitively; `proc_name` truncates long names, so prefixes rather than whole names.
    private static let prefixes = ["logioptionsplus", "logipluginservice", "logi_cp", "com.logi.cp-dev-mgr"]

    static func isLogiOptions(processName name: String) -> Bool {
        let name = name.lowercased()
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Names of running Logi Options+ processes, sorted and without duplicates. Only this user's
    /// processes have readable names, so a root updater goes unseen, but the per-user agent that
    /// drives the mouse (`logioptionsplus_agent`) is found.
    static func running() -> [String] {
        let capacity = proc_listallpids(nil, 0) + 64  // headroom for processes started meanwhile
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var names: Set<String> = []
        for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
            var buffer = [UInt8](repeating: 0, count: 64)
            let length = Int(proc_name(pid, &buffer, UInt32(buffer.count)))
            guard length > 0 else { continue }
            let name = String(decoding: buffer.prefix(length), as: UTF8.self)
            if isLogiOptions(processName: name) { names.insert(name) }
        }
        return names.sorted()
    }

    static func warnIfRunning() {
        let names = running()
        guard !names.isEmpty else { return }
        Log.error("Logi Options+ is running (\(names.joined(separator: ", "))) and will fight mxd over the mouse; "
                  + "quit it or uninstall it with Logitech's uninstaller")
    }
}
