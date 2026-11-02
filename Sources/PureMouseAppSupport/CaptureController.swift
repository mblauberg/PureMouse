import Foundation
import Observation
import PureMouseKit

/// Select by pressing: asks the daemon to report the next control pressed (`Control.capture`)
/// and follows its answer in the status. The daemon gives up after 10 s; `timeout` covers a
/// daemon that never answers.
@MainActor @Observable
public final class CaptureController {
    public private(set) var listening = false
    /// How the last capture ended, while it is worth saying: set when nothing was pressed in
    /// time, cleared by the next start, a press, a cancel or `clearOutcome()`.
    public private(set) var outcome: Outcome?
    /// The config key of the control just pressed; the Buttons pane highlights it and opens its picker.
    public var capturedButton: String?
    /// The device key of the mouse that was pressed (`Status.Capture.model`), when it said.
    public private(set) var capturedDevice: String?
    /// Called when a control is pressed, with the mouse's device key if the daemon gave one, before
    /// `capturedButton` is set, so a pane can switch to that mouse's scope first.
    @ObservationIgnored public var pressed: @MainActor (String?) -> Void = { _ in }

    public enum Outcome: Equatable, Sendable {
        case noButtonDetected

        /// What the Mouse tab's header strip shows, and VoiceOver announces.
        public var message: String {
            switch self {
            case .noButtonDetected: "No button detected. Try again."
            }
        }
    }

    /// How long to wait for the daemon's answer before cancelling.
    static let timeout: TimeInterval = 11

    @ObservationIgnored private let link: DaemonLink
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let newToken: () -> Int
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var cancelTimeout: Clock.Cancel?

    public init(link: DaemonLink, clock: Clock = .main,
                newToken: @escaping () -> Int = RequestToken.random) {
        self.link = link
        self.clock = clock
        self.newToken = newToken
    }

    /// Starts listening on every mouse, or only the one with this device key (`Control.Capture.device`).
    public func start(device: String? = nil) {
        guard link.daemonRunning, !link.paused else { return }
        // A restart replaces the running request, and its timeout with it.
        cancelTimeout?()
        cancelTimeout = nil
        token = newToken()
        listening = true
        capturedButton = nil
        capturedDevice = nil
        outcome = nil
        let request = Control.Capture(token: token, device: device)
        guard link.writeControl({ $0.capture = request }) else {
            stopListening()
            return
        }
        cancelTimeout = clock.after(Self.timeout) { [weak self] in self?.timedOut() }
    }

    /// Ends a capture under way, and forgets how an earlier one ended: leaving Buttons by any
    /// route calls this, and a "No button detected" left from a timeout must not outlive it.
    public func cancel() {
        if listening { end() }
        outcome = nil
    }

    /// The daemon never answered: stop it, and say nothing was pressed.
    private func timedOut() {
        guard listening else { return }
        end()
        outcome = .noButtonDetected
    }

    /// Forgets the outcome (the Mouse tab left Buttons, say).
    public func clearOutcome() { outcome = nil }

    /// Stops listening; with `notify`, tells a running daemon to stop too, unless another
    /// process has started a capture of its own since.
    public func end(notify: Bool = true) {
        stopListening()
        outcome = nil
        let mine = token
        if notify, link.daemonRunning {
            link.writeControl { if $0.capture?.token == mine { $0.capture = nil } }
        }
    }

    /// A capture ends with the daemon.
    public func checkDaemon() {
        if !link.daemonRunning, listening { end() }
    }

    /// Follows the daemon's progress for this process's request.
    public func handle(_ capture: Status.Capture) {
        guard listening, capture.token == token else { return }
        switch capture.state {
        case .listening:
            break
        case .pressed:
            stopListening()
            capturedDevice = capture.model
            pressed(capture.model)
            capturedButton = capture.cid.map(NamedButton.config(cid:))
        case .timedOut:
            stopListening()
            outcome = .noButtonDetected
        case .cancelled:
            stopListening()
        }
    }

    private func stopListening() {
        listening = false
        cancelTimeout?()
        cancelTimeout = nil
    }
}
