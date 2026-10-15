import Foundation
import notify
import PureMouseKit

/// The daemon's side of the menu bar app's channel (docs/companion.md): writes `status.json`
/// whenever the status changes and rings its doorbell, and listens for the menu's control doorbell.
/// Nothing here runs while idle.
@MainActor
final class StatusChannel {
    private let make: () -> Status
    private var scheduled = false
    private var last: Status?
    private var controlToken: Int32 = NOTIFY_TOKEN_INVALID

    init(make: @escaping () -> Status) {
        self.make = make
    }

    /// Writes the status at the end of this main-queue turn, so a burst of changes costs one write.
    func setNeedsWrite() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scheduled else { return }
                self.writeNow()
            }
        }
    }

    /// Writes the status now if it differs from the last one written.
    func writeNow() {
        scheduled = false
        let status = make()
        guard status != last else { return }
        do {
            try Companion.write(status, to: Companion.statusURL)
            last = status
            notify_post(Companion.statusNotification)
        } catch {
            Log.error("writing \(Companion.statusURL.path): \(error)")
        }
    }

    /// Calls `handler` on the main queue each time the menu bar app posts a control change.
    func onControl(_ handler: @escaping @MainActor () -> Void) {
        let status = notify_register_dispatch(Companion.controlNotification, &controlToken, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        if status != NOTIFY_STATUS_OK { Log.error("listening for control changes failed: \(status)") }
    }

    /// Requests left by a previous run must not apply to this one (a pause never outlives the daemon).
    static func clearControl() {
        do {
            try FileManager.default.removeItem(at: Companion.controlURL)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Log.error("removing \(Companion.controlURL.path): \(error)")
        }
    }
}
