import Foundation

/// Runs work later on the main queue. The live clock uses `DispatchQueue.main.asyncAfter`; tests
/// inject one whose work they run by hand, so nothing waits on real time. It is a one-shot delay,
/// never a repeating timer.
public struct Clock {
    /// Cancels the work if it has not run yet.
    public typealias Cancel = @MainActor () -> Void

    public var after: @MainActor (_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel

    public init(after: @escaping @MainActor (_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel) {
        self.after = after
    }

    @MainActor public static var main: Clock {
        Clock { seconds, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            return { item.cancel() }
        }
    }
}
