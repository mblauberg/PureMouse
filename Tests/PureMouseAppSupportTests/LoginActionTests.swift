import PureMouseKit
import Testing
@testable import PureMouseAppSupport

@Suite struct LoginActionTests {
    @Test func theOpenAtLoginSwitchRunsOnlyLoginCommands() {
        #expect(LoginAction.openAtLogin(true).command == .loginOn)
        #expect(LoginAction.openAtLogin(false).command == .loginOff)
        #expect(LoginAction.openAtLogin(true).command.arguments == ["login", "on"])
        #expect(LoginAction.openAtLogin(false).command.arguments == ["login", "off"])
    }

    /// Stop and Start change what runs, never the registration: neither is `register`,
    /// `unregister` or `login on|off`.
    @Test func startAndStopRunOnlyTheCommandsThatChangeNoRegistration() {
        #expect(LoginAction.running(false).command == .stop)
        #expect(LoginAction.running(true).command == .start)
        #expect(LoginAction.running(false).command.arguments == ["stop"])
        #expect(LoginAction.running(true).command.arguments == ["start"])
    }

    @Test func noControlRunsRegisterOrUnregister() {
        let all: [LoginAction] = [.openAtLogin(true), .openAtLogin(false), .running(true), .running(false)]
        for action in all {
            #expect(!["register", "unregister"].contains(action.command.arguments.first))
        }
    }

    private func status(daemon: JobStatus, menu: JobStatus = .notRegistered) -> LoginStatus {
        LoginStatus(service: "launchd", daemon: daemon, menu: menu, hidden: false)
    }

    @Test func theSwitchReadsLoginStatus() {
        #expect(!OpenAtLogin(nil).isOn)
        #expect(!OpenAtLogin(status(daemon: .notRegistered)).isOn)
        #expect(OpenAtLogin(status(daemon: .enabled)).isOn)
        #expect(!OpenAtLogin(status(daemon: .enabled)).needsApproval)
    }

    @Test func aJobWaitingForApprovalKeepsTheSwitchOnAndExplainsHowToApprove() {
        for waiting in [status(daemon: .requiresApproval), status(daemon: .enabled, menu: .requiresApproval)] {
            #expect(OpenAtLogin(waiting).needsApproval)
        }
        #expect(OpenAtLogin(status(daemon: .requiresApproval)).isOn)
        #expect(!OpenAtLogin(nil).needsApproval)
    }
}
