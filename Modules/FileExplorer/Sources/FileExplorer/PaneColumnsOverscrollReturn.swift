import AppKit
import Events
import SwiftUI

/// Returns the column stack from an overscrolled position when the platform fails to.
///
/// The stack is a horizontal `ScrollView` whose children are `List`s — nested scroll views. Wheel
/// events over a column are handled by the column's own (vertical) scroll view and forwarded up
/// to the stack for the horizontal axis, and that forwarding loses the gesture's phase: the stack
/// sees deltas but never a clean "gesture ended". AppKit's rubber band springs back on exactly
/// that signal, so an overscrolled stack just stays stretched until some unrelated event — moving
/// the mouse out of the pane, a hover change — happens to re-run the constraint. That is the
/// reported "bounces back only after the mouse moves out of the pane", and it is also why the
/// previous machinery (`63bb6cf`→`7021b28`, since removed) kept getting stuck: it keyed its
/// spring on `didEndLiveScroll`, a signal from the same broken channel.
///
/// So this watches STATE, not signals. Every bounds change of the stack's clip view (its own,
/// SwiftUI-configured clip view — nothing is swapped or overridden here) re-arms a short timer.
/// While anything is actually moving — a drag, momentum, the native spring when it does work —
/// the timer never fires. When the stack comes to rest, the timer fires once; if it is resting
/// OUT of its legal range, it is animated home. A working native bounce settles in range and the
/// check is a no-op, so the watchdog cannot fight the platform on the paths the platform handles.
///
/// Placed as a zero-size `.background` INSIDE the horizontal `ScrollView`, so the ancestor walk
/// resolves that scroll view and not a column's list — a column's scroll view hosts an
/// `NSTableView` as its document, the stack's does not.
struct PaneColumnsOverscrollReturn: NSViewRepresentable {
    func makeNSView(context: Context) -> WatchdogView { WatchdogView() }
    /// A SwiftUI update can rebuild the scroll view under us, so re-resolve rather than trusting
    /// one pass.
    func updateNSView(_ view: WatchdogView, context: Context) { view.rearm() }

    final class WatchdogView: NSView {
        private weak var observedScroller: NSScrollView?
        /// The scroll view the watchdog is currently guarding — exposed so the mounted test can
        /// assert the ancestor walk resolved the STACK's scroll view and not a column's list.
        var resolvedScroller: NSScrollView? { observedScroller }
        private var observers: [NSObjectProtocol] = []
        private var pendingCheck: DispatchWorkItem?
        /// Bounds the ancestor walk: `layout()` runs on every pass, and a hierarchy this can never
        /// resolve would otherwise re-walk the ancestry forever.
        private var budget = WatchdogView.searchesPerChange
        private static let searchesPerChange = 4

        /// How long the stack must rest before the check runs. Long enough that a momentum tail's
        /// sparse deltas (frame-cadence, ~16ms apart) keep deferring it; short enough that the
        /// return reads as a bounce, not a correction.
        static let quiescence: TimeInterval = 0.14

        /// How far out of range a resting origin must be before it is worth a pull.
        ///
        /// Not an optimisation — the loop-breaker. SwiftUI parks the clip at fractional origins
        /// (pixel alignment on Retina), so a zero-tolerance watchdog pulls the origin to the
        /// mathematically legal point, SwiftUI re-parks it a fraction off, the bounds change
        /// re-arms the timer, and the "correction" repeats every quiescence interval forever —
        /// 18,000 pulls in one night, each an animated `setBoundsOrigin`, visible as a shimmer on
        /// the pane while scrolling. A stranding the eye can see is tens of points; anything
        /// under this threshold is noise that must be left exactly where SwiftUI put it.
        static let tolerance: CGFloat = 2

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Torn down here rather than in `deinit`: a nonisolated `deinit` cannot touch
            // non-Sendable stored state. Re-entering a window re-arms explicitly below — the
            // previous styler released observers on exit and never re-attached on re-entry.
            guard window != nil else { return teardown() }
            rearm()
        }

        private func teardown() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedScroller = nil
            pendingCheck?.cancel()
            pendingCheck = nil
        }

        override func layout() {
            super.layout()
            // Also covers out-of-range states no gesture produced (a column closing while the
            // stack sits at its far end). Only arms a timer — the correction itself never runs
            // inside a layout pass.
            resolveAndObserve()
            scheduleCheck()
        }

        func rearm() {
            budget = Self.searchesPerChange
            DispatchQueue.main.async { [weak self] in
                self?.resolveAndObserve()
                self?.scheduleCheck()
            }
        }

        private func resolveAndObserve() {
            guard window != nil else { return }
            if let observedScroller, observedScroller.window === window, !observers.isEmpty { return }
            guard budget > 0 else { return }
            budget -= 1
            guard let scroller = Self.findStackScrollView(from: self) else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            let clip = scroller.contentView
            clip.postsBoundsChangedNotifications = true
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleCheck() }
                }
            ]
            observedScroller = scroller
        }

        /// Re-arms the quiescence timer. Called on every bounds change, so the check only ever
        /// runs once the stack has actually stopped moving.
        private func scheduleCheck() {
            guard observedScroller != nil else { return }
            pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.returnHomeIfStranded() }
            pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiescence, execute: work)
        }

        private func returnHomeIfStranded() {
            guard let scroller = observedScroller else { return }
            let clip = scroller.contentView
            let origin = clip.bounds.origin
            let home = Self.legalOrigin(for: origin, clip: clip)
            guard max(abs(home.x - origin.x), abs(home.y - origin.y)) >= Self.tolerance else { return }
            // Every pull is logged — fractional, because `%.0f` is exactly how a sub-point
            // correction loop hid as "pull (0, 0) → (0, 0)" for a night of 18,000 lines.
            Logger.shared.debug(String(
                format: "[stack] pull (%.2f, %.2f) → (%.2f, %.2f), doc %.1f×%.1f clip %.1f×%.1f",
                origin.x, origin.y, home.x, home.y,
                clip.documentView?.frame.width ?? -1, clip.documentView?.frame.height ?? -1,
                clip.bounds.width, clip.bounds.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clip.setBoundsOrigin(home)
            }
            scroller.reflectScrolledClipView(clip)
        }

        /// The nearest legal resting origin. Static and internal so the clamp can be pinned
        /// directly; the mounted test drives the whole watchdog.
        ///
        /// Measured from the document's FRAME, not from zero: when the document is wider than the
        /// clip the legal band is [minX, maxX − clipWidth] as usual, and when it is *narrower* —
        /// the left pane resting with three columns in a wide pane, doc 420 in a clip 772 — the
        /// band collapses to the leading edge, which is where SwiftUI parks fitting content. A
        /// zero-based clamp got that case wrong and turned the wrong answer into a repeating
        /// pull; see `tolerance`.
        /// Content insets widen the legal band: an inset clip legally RESTS at a negative origin
        /// (`-insets.top`), and clamping that to the document edge would repeat the stack's
        /// pull-forever mistake on any inset list. The pane's clips measure zero insets today, so
        /// this is armor, not a behavior change.
        static func legalOrigin(for origin: NSPoint, clip: NSClipView) -> NSPoint {
            guard let document = clip.documentView else { return origin }
            let frame = document.frame
            let insets = clip.contentInsets
            let lowX = frame.minX - insets.left
            let lowY = frame.minY - insets.top
            let highX = max(lowX, frame.maxX + insets.right - clip.bounds.width)
            let highY = max(lowY, frame.maxY + insets.bottom - clip.bounds.height)
            return NSPoint(
                x: min(max(origin.x, lowX), highX),
                y: min(max(origin.y, lowY), highY))
        }

        /// The nearest enclosing scroll view that is NOT one of the columns' lists.
        ///
        /// A column's scroll view hosts the column's `NSTableView`; the stack's hosts the row of
        /// columns. `documentView` is checked rather than searching the subtree, because the
        /// stack's document view CONTAINS tables and a subtree search would call it a column.
        static func findStackScrollView(from start: NSView?) -> NSScrollView? {
            var view = start?.superview
            while let current = view {
                if let scroller = current as? NSScrollView,
                   !(scroller.documentView is NSTableView) { return scroller }
                view = current.superview
            }
            return nil
        }
    }
}
