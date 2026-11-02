import Foundation

/// `UpdateScheduling` over `NSBackgroundActivityScheduler`: the system picks the moment, within the
/// tolerance, and defers it while the Mac sleeps, runs on battery in a low state or is busy. It
/// owns no timer, so a menu bar app that is idle costs nothing.
@MainActor
public final class BackgroundActivity: UpdateScheduling {
    private let identifier: String
    private var scheduler: NSBackgroundActivityScheduler?

    /// How long after the nominal time the system may wait for a convenient moment.
    static let tolerance: TimeInterval = 60 * 60
    /// The shortest nominal delay; a check that is already due still waits this long after launch.
    static let minimumDelay: TimeInterval = 60

    public init(identifier: String) { self.identifier = identifier }

    public func schedule(after delay: TimeInterval,
                         work: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void) {
        cancel()
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = false
        scheduler.interval = max(delay, Self.minimumDelay)
        scheduler.tolerance = Self.tolerance
        scheduler.qualityOfService = .utility
        self.scheduler = scheduler
        let handle = SchedulerBox(scheduler)
        scheduler.schedule { completion in
            // Asked to give way (busy or asleep): the system runs the activity again later.
            if handle.scheduler.shouldDefer {
                completion(.deferred)
                return
            }
            let finish = CompletionBox(completion)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work { finish.call(.finished) } }
            }
        }
    }

    public func cancel() {
        scheduler?.invalidate()
        scheduler = nil
    }
}

/// The scheduler's completion handler, handed from its queue to the main actor and called once.
private final class CompletionBox: @unchecked Sendable {
    private let completion: NSBackgroundActivityScheduler.CompletionHandler
    init(_ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) { self.completion = completion }
    func call(_ result: NSBackgroundActivityScheduler.Result) { completion(result) }
}

/// The scheduler, read for `shouldDefer` from the queue its handler runs on (the property is made for that).
private final class SchedulerBox: @unchecked Sendable {
    let scheduler: NSBackgroundActivityScheduler
    init(_ scheduler: NSBackgroundActivityScheduler) { self.scheduler = scheduler }
}
