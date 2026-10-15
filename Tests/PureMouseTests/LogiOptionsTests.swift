import Testing
@testable import puremouse

@Suite struct LogiOptionsTests {
    @Test func matchesItsProcesses() {
        // proc_name truncates, so the helper names arrive cut short.
        for name in ["logioptionsplus_agent", "logioptionsplus_updater", "logioptionsplus",
                     "logioptionsplus Helper (Renderer", "LogiPluginService", "LogiPluginServiceNative",
                     "logi_cp_dev_mgr", "com.logi.cp-dev-mgr"] {
            #expect(LogiOptions.isLogiOptions(processName: name), "\(name)")
        }
    }

    @Test func ignoresLookalikes() {
        for name in ["login", "logind", "loginwindow", "puremouse", "Logic Pro X", "logi_crashpad_handler"] {
            #expect(!LogiOptions.isLogiOptions(processName: name), "\(name)")
        }
    }
}
