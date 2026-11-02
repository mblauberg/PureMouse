import Foundation
import Observation
import PureMouseKit

/// Select by pressing: asks the daemon to report the next control pressed (`Control.capture`)
/// and follows its answer in the status. The daemon gives up after 10 s; `timeout` covers a
/// daemon that never answers.
@MainActor @Observable
public final class CaptureController {
    public private(set) var listening = false
    /// The config key of the control just pressed; the Buttons pane highlights it and opens its picker.
    public var capturedButton: String?

    /// How long to wait for the daemon's answer before cancelling.
    public static let timeout: TimeInterval = 11

    @ObservationIgnored private let link: DaemonLink
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let newToken: () -> Int
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var cancelTimeout: Clock.Cancel?

    public init(link: DaemonLink, clock: Clock = .main,
                newToken: @escaping () -> Int = { Int.random(in: 1...Int(Int32.max)) }) {
        self.link = link
        self.clock = clock
        self.newToken = newToken
    }

    public func start() {
        guard link.daemonRunning, !link.paused else { return }
        token = newToken()
        listening = true
        capturedButton = nil
        link.capture = Control.Capture(token: token)
        guard link.writeControl() else {
            stopListening()
            return
        }
        cancelTimeout = clock.after(Self.timeout) { [weak self] in self?.cancel() }
    }

    public func cancel() {
        guard listening else { return }
        end()
    }

    /// Stops listening; with `notify`, tells a running daemon to stop too.
    public func end(notify: Bool = true) {
        stopListening()
        if notify, link.daemonRunning { link.writeControl() }
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
            capturedButton = capture.cid.map(NamedButton.config(cid:))
        case .timedOut, .cancelled:
            stopListening()
        }
    }

    private func stopListening() {
        listening = false
        link.capture = nil
        cancelTimeout?()
        cancelTimeout = nil
    }
}
