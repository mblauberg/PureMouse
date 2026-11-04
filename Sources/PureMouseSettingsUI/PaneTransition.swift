import AppKit

/// The one owner of the Settings window's frame (docs/ui-design.md, Motion and Sizing). A page
/// change (a tab, a Mouse segment, an app's page and back) runs `change`: the old page is
/// snapshotted, the change is made and laid out, and one transaction starts the window frame moving
/// to the new page's height while the snapshot fades out and the new page fades in, with one duration
/// and curve. A height change inside a page (`fit`) moves the frame the same way, with no fade.
///
/// While either runs, the page's container (the tab view) is held against the top of the window at
/// the new height, so nothing slides as the frame moves: the window's bottom edge covers or uncovers
/// the page. Left to the tab controller's own constraints (top and bottom at priority 749, above the
/// window's own height at 500), the tab view takes the new height before the window does and sits
/// against the bottom, so the page slid with the frame. A hidden window and Reduce Motion take the
/// new size at once, as AppKit does.
@MainActor
final class PaneTransition {
    /// How a change shows.
    enum Style: Equatable {
        /// The page swaps and the window takes its new size at once.
        case instant
        /// One transition of this length: the pages cross-fade, and the frame moves if the
        /// height changed.
        case animated(TimeInterval)
    }

    /// The shortest and longest a page change takes. AppKit's own resize time (about 0.2 s per
    /// 150 pt) sets it between them, so a fade with little or no height change is still seen.
    static let durations: ClosedRange<TimeInterval> = 0.2...0.35

    static func style(visible: Bool, reduceMotion: Bool, resizeTime: TimeInterval) -> Style {
        guard visible, !reduceMotion else { return .instant }
        return .animated(min(max(resizeTime, durations.lowerBound), durations.upperBound))
    }

    /// Whether the system asks for less motion; replaced in tests.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Animation dependencies are replaceable for deterministic lifecycle tests.
    var isVisible: (NSWindow) -> Bool = { $0.isVisible }
    var now: () -> TimeInterval = { CACurrentMediaTime() }
    var animateGroup: (TimeInterval, @escaping () -> Void, @escaping @MainActor @Sendable () -> Void) -> Void = { duration, changes, completion in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// The view the snapshot covers: the window's content view (the tab controller's).
    private unowned let host: NSView
    /// The window frame that fits the page now, or nil when there is nothing to measure.
    private let target: () -> NSRect?
    /// The view that holds the page (the tab view): held at the top while the frame moves, and
    /// faded in over a page change.
    private let container: () -> NSView?

    /// How many `change` calls are open: only the outermost one snapshots and animates.
    private var depth = 0
    /// The old page, taken by `begin` for `end`.
    private var snapshot: NSView?
    private var flight: Flight?
    private var nextFlight = 0

    private static let fadeKey = "PaneTransition.fadeIn"

    /// An animation under way: its destination, pins and original end time.
    private struct Flight {
        let id: Int
        var target: NSRect
        var snapshot: NSView?
        var pins: [NSLayoutConstraint] = []
        /// The tab controller's own bottom constraints, off while the page is pinned.
        var released: [NSLayoutConstraint] = []
        var frameGeneration = 0
        var framePending = false
        var fadePending = false
        let deadline: TimeInterval
    }

    init(host: NSView, target: @escaping () -> NSRect?, container: @escaping () -> NSView?) {
        self.host = host
        self.target = target
        self.container = container
    }

    /// Whether a change is being made (between `begin` and `end`): the frame waits for it.
    var isChanging: Bool { depth > 0 }

    /// Whether an animation is under way.
    var isAnimating: Bool { flight != nil }

    /// Makes a page change as one transition. Nested calls join the outer one.
    func change(_ swap: () -> Void) {
        begin()
        swap()
        end()
    }

    /// Starts a page change: ends one under way at once, and snapshots the page as it is.
    func begin() {
        depth += 1
        guard depth == 1 else { return }
        settle()
        snapshot = takeSnapshot()
        // The new page stays hidden under the snapshot until its fade starts: AppKit and SwiftUI
        // can draw between the swap and the animation, which showed both pages for a frame.
        if snapshot != nil { setPageOpacity(0) }
    }

    /// Ends a page change: lays the new page out, measures it and starts the frame and fade.
    func end() {
        depth -= 1
        guard depth == 0 else { return }
        let snapshot = self.snapshot
        self.snapshot = nil
        // Layout can consume an app-page request and call change again. Keep it inside this
        // change so it joins the snapshot already taken rather than starting a second flight.
        depth = 1
        // Twice: a change can set state that a pane acts on in its first update (a request for an
        // app's page), which then changes what it shows.
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let window = host.window
        let target = window == nil ? nil : target()
        depth = 0
        guard let window, let target else {
            snapshot?.removeFromSuperview()
            setPageOpacity(1)
            return
        }
        animate(window, to: target, fading: snapshot)
    }

    /// Fits the window to the page after its height changed in place (a disclosure, a notice): the
    /// frame moves as in a page change, with no fade. A change being made fits when it ends.
    func fit() {
        guard !isChanging, let window = host.window else { return }
        if var flight {
            let target = target() ?? flight.target
            // Policy may have changed even when the measured target has not.
            guard case .animated = Self.style(visible: isVisible(window), reduceMotion: reduceMotion(),
                                               resizeTime: window.animationResizeTime(target)),
                  flight.deadline > now() else {
                flight.target = target
                self.flight = flight
                settle()
                return
            }
            guard flight.target != target else { return }
            flight.target = target
            self.flight = flight
            pin(height: window.contentRect(forFrameRect: target).height)
            runFrame(window, to: target, duration: max(0, flight.deadline - now()), id: flight.id)
        } else {
            guard let target = target(), window.frame != target else { return }
            animate(window, to: target, fading: nil)
        }
    }

    /// Ends an outstanding change when the window closes, including a snapshot taken before `end`.
    func cancel() {
        snapshot?.removeFromSuperview()
        snapshot = nil
        setPageOpacity(1)
        settle()
    }

    // MARK: Running

    private func animate(_ window: NSWindow, to target: NSRect, fading snapshot: NSView?) {
        let style = Self.style(visible: isVisible(window), reduceMotion: reduceMotion(),
                               resizeTime: window.animationResizeTime(target))
        guard case .animated(let duration) = style, window.frame != target || snapshot != nil else {
            snapshot?.removeFromSuperview()
            setPageOpacity(1)
            if window.frame != target { window.setFrame(target, display: isVisible(window)) }
            return
        }
        nextFlight += 1
        let id = nextFlight
        flight = Flight(id: id, target: target, snapshot: snapshot, framePending: true, deadline: now() + duration)
        pin(height: window.contentRect(forFrameRect: target).height)
        // Separate completion ownership: replacing a frame animation can complete its AppKit
        // group immediately. It must neither complete the fade nor release the page's pins.
        CATransaction.begin()
        if let snapshot {
            flight?.fadePending = true
            animateGroup(duration, { [self] in
                snapshot.animator().alphaValue = 0
                if let layer = container()?.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.opacity = 1
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = duration
                    fade.beginTime = layer.convertTime(now(), from: nil)
                    fade.fillMode = .backwards
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(fade, forKey: Self.fadeKey)
                    CATransaction.commit()
                }
            }, { [weak self] in
                guard let self, flight?.id == id else { return }
                flight?.fadePending = false
                finishIfReady()
            })
        }
        runFrame(window, to: target, duration: duration, id: id)
        CATransaction.commit()
    }

    /// Retargets share the original deadline; only the latest frame completion owns the pins.
    private func runFrame(_ window: NSWindow, to target: NSRect, duration: TimeInterval, id: Int) {
        flight?.frameGeneration += 1
        let generation = flight?.frameGeneration
        flight?.framePending = true
        animateGroup(duration, {
            if window.frame != target { window.animator().setFrame(target, display: true) }
        }, { [weak self] in
            guard let self, flight?.id == id, flight?.frameGeneration == generation else { return }
            flight?.framePending = false
            finishIfReady()
        })
    }

    private func finishIfReady() {
        guard let flight, !flight.framePending, !flight.fadePending else { return }
        land()
    }

    /// Layer opacity does not take the live view out of AppKit hit testing. Before a swap it is
    /// zero; the final model value and explicit fade are installed together before commit.
    private func setPageOpacity(_ opacity: Float) {
        guard let page = container() else { return }
        page.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.layer?.opacity = opacity
        CATransaction.commit()
    }

    /// Ends an animation under way at once: the frame at its target, the snapshot gone, the page
    /// shown and unpinned.
    private func settle() {
        guard let flight, let window = host.window else { return land() }
        if window.frame != flight.target { window.setFrame(flight.target, display: isVisible(window)) }
        land()
    }

    private func land() {
        guard let flight else { return }
        self.flight = nil
        flight.snapshot?.removeFromSuperview()
        if let page = container() {
            setPageOpacity(1)
            page.layer?.removeAnimation(forKey: Self.fadeKey)
        }
        guard !flight.pins.isEmpty else { return }
        NSLayoutConstraint.deactivate(flight.pins)
        NSLayoutConstraint.activate(flight.released)
        host.layoutSubtreeIfNeeded()
        fillContainer()
    }

    // MARK: Snapshot and pin

    /// The page as drawn now, in a view over it pinned to the top. Only the content is drawn, with
    /// the window's background left clear, so the real background (tinted by the desktop) shows
    /// through: a snapshot with the background drawn in did not match it. Nil when the change will
    /// not animate.
    private func takeSnapshot() -> NSView? {
        guard let window = host.window, isVisible(window), !reduceMotion(),
              host.bounds.width > 0, host.bounds.height > 0,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let view = SnapshotView(frame: host.bounds)
        view.wantsLayer = true
        view.layer?.contents = rep.cgImage
        view.layer?.contentsScale = window.backingScaleFactor
        view.autoresizingMask = [.width, host.isFlipped ? .maxYMargin : .minYMargin]
        host.addSubview(view, positioned: .above, relativeTo: nil)
        return view
    }

    /// Holds the page's container at `height` against the top of the window's content, so the
    /// frame's bottom edge moves over the page instead of the page moving with it.
    private func pin(height: CGFloat) {
        guard var flight, let container = container() else { return }
        if flight.pins.isEmpty {
            // The container's bottom is tied to the window's (the tab controller's, at 749), which
            // with a fixed height would size the window through layout at once, outrunning the
            // animation: it is let go until the frame arrives.
            flight.released = host.constraints.filter { constraint in
                constraint.isActive && [constraint.firstItem, constraint.secondItem].contains { $0 === container }
                    && [constraint.firstAttribute, constraint.secondAttribute].contains(.bottom)
            }
            NSLayoutConstraint.deactivate(flight.released)
            flight.pins = [container.topAnchor.constraint(equalTo: host.topAnchor),
                           container.heightAnchor.constraint(equalToConstant: height)]
            NSLayoutConstraint.activate(flight.pins)
        } else {
            flight.pins[1].constant = height
        }
        self.flight = flight
        host.layoutSubtreeIfNeeded()
        fillContainer()
    }

    /// Gives the selected page the tab view's whole content area, as the tab view itself would.
    private func fillContainer() {
        guard let tabView = container() as? NSTabView,
              let page = tabView.selectedTabViewItem?.view else { return }
        if page.frame != tabView.contentRect { page.frame = tabView.contentRect }
    }
}

/// A visual copy of the old page never intercepts input or appears to assistive technology.
@MainActor
final class SnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }
}
