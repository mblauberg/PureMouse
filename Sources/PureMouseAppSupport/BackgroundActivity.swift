import Foundation

/// `UpdateScheduling` over `NSBackgroundActivityScheduler`: the system picks the moment, within the
/// tolerance, and defers it while the Mac sleeps, runs on battery in a low state or is busy. It
/// owns no timer, so a menu bar app that is idle costs nothing.
@MainActor
public final class BackgroundActivity: UpdateScheduling {
    private let identifier: String
    private var scheduler: NSBackgroundActivityScheduler?

    /// The most the system may move the run, earlier or later than the nominal time, for a convenient moment.
    static let maximumTolerance: TimeInterval = 60 * 60
    /// The shortest nominal delay; a check that is already due still waits this long after launch.
    static let minimumDelay: TimeInterval = 60

    /// The scheduler's interval and tolerance for a wanted delay. The system may run the activity
    /// up to the tolerance before its interval is up as well as after, so the interval is the delay
    /// plus the tolerance and the earliest run is the delay itself. The scheduler raises an
    /// exception unless the tolerance is less than the interval, so a short wait gets a short tolerance.
    static func timing(after delay: TimeInterval) -> (interval: TimeInterval, tolerance: TimeInterval) {
        let wait = max(delay, minimumDelay)
        let tolerance = min(maximumTolerance, wait / 2)
        return (wait + tolerance, tolerance)
    }

    public init(identifier: String) { self.identifier = identifier }

    public func schedule(after delay: TimeInterval,
                         work: @escaping @MainActor (_ done: @escaping @MainActor () -> Void) -> Void) {
        cancel()
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = false
        let timing = Self.timing(after: delay)
        scheduler.interval = timing.interval
        scheduler.tolerance = timing.tolerance
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
