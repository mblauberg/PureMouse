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

    /// Start changes what runs, never the registration: it is not `register`, `unregister` or
    /// `login on|off`. Settings has no Stop.
    @Test func startRunsOnlyTheCommandThatChangesNoRegistration() {
        #expect(LoginAction.start.command == .start)
        #expect(LoginAction.start.command.arguments == ["start"])
    }

    @Test func noControlRunsRegisterOrUnregister() {
        let all: [LoginAction] = [.openAtLogin(true), .openAtLogin(false), .start]
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
