import Foundation

/// Something Settings tells the user about: shown as the one banner at the top of a pane, and as
/// a row in General's Status section. The cases are in priority order.
public enum Notice: CaseIterable, Sendable {
    /// The config file does not parse or validate; settings are read-only.
    case configError
    /// A change could not be saved.
    case writeError
    /// The status file is newer than this app understands.
    case statusTooNew
    /// PureMouse is not running.
    case off
    case paused
    /// Logi Options+ is running and holds the buttons.
    case logiOptions
    /// Accessibility is not allowed; only on panes whose settings need it.
    case accessibility

    /// What a notice's own button does: Start PureMouse runs `start`, never `register`, so Open
    /// at login stays as it is (docs/adr/0018-login-service-seam.md).
    public var loginAction: LoginAction? { self == .off ? .running(true) : nil }
}

/// Which notices apply, highest priority first. A pane shows the first as its banner and offers
/// the rest in General; General lists every one.
public enum BannerPlan {
    public struct State: Equatable, Sendable {
        public var configError = false
        public var writeError = false
        public var statusTooNew = false
        public var daemonRunning = true
        public var paused = false
        public var logiOptionsRunning = false
        public var accessibilityMissing = false
        /// The pane's settings do nothing without Accessibility (buttons, scrolling, apps).
        public var needsAccessibility = false

        public init(configError: Bool = false, writeError: Bool = false, statusTooNew: Bool = false,
                    daemonRunning: Bool = true, paused: Bool = false, logiOptionsRunning: Bool = false,
                    accessibilityMissing: Bool = false, needsAccessibility: Bool = false) {
            self.configError = configError
            self.writeError = writeError
            self.statusTooNew = statusTooNew
            self.daemonRunning = daemonRunning
            self.paused = paused
            self.logiOptionsRunning = logiOptionsRunning
            self.accessibilityMissing = accessibilityMissing
            self.needsAccessibility = needsAccessibility
        }
    }

    /// The notices that apply, in the order of `Notice`'s cases.
    public static func items(for state: State) -> [Notice] {
        var items: [Notice] = []
        if state.configError { items.append(.configError) }
        if state.writeError { items.append(.writeError) }
        if state.statusTooNew { items.append(.statusTooNew) }
        if !state.daemonRunning { items.append(.off) }
        if state.paused { items.append(.paused) }
        if state.logiOptionsRunning { items.append(.logiOptions) }
        if state.needsAccessibility, state.accessibilityMissing { items.append(.accessibility) }
        return items
    }

    /// "1 more notice", "3 more notices": what a banner says of the notices behind it.
    public static func moreText(_ count: Int) -> String? {
        count < 1 ? nil : count == 1 ? "1 more notice" : "\(count) more notices"
    }
}

extension BannerPlan.State {
    @MainActor public init(model: AppModel, needsAccessibility: Bool) {
        self.init(configError: model.configError != nil, writeError: model.writeError != nil,
                  statusTooNew: model.statusTooNew, daemonRunning: model.daemonRunning, paused: model.paused,
                  logiOptionsRunning: model.logiOptionsRunning, accessibilityMissing: model.accessibilityMissing,
                  needsAccessibility: needsAccessibility)
    }
}

/// Whether PureMouse is running now, for General's Status row.
public enum RunState: Equatable, Sendable {
    case running, paused, off

    public init(daemonRunning: Bool, paused: Bool) {
        self = !daemonRunning ? .off : paused ? .paused : .running
    }

    public var word: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .off: "Off"
        }
    }

    /// The Status row's button: Start while off, else Stop. Neither changes Open at login.
    public var button: LoginAction { self == .off ? .running(true) : .running(false) }
}

/// The question asked before Use Last Working Config replaces the config file.
public enum UseLastWorkingConfirmation {
    public static let title = "Use the last working config?"
    public static let button = "Use Last Working Config"

    public static func message(backupName: String) -> String {
        "This replaces the whole config file with the last one that worked. The current file is saved as \(backupName), replacing any earlier backup."
    }
}
