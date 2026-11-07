import AppKit
import Events
import SwiftUI

/// Which axis the current wheel gesture belongs to, decided once per gesture from accumulated
/// early deltas: the axis lock Finder's column view applies.
///
/// A vertical trackpad scroll is never purely vertical, and its small horizontal deltas leak
/// through the column list to the stack. With two or more columns open, every vertical scroll would
/// nudge the stack sideways and the watchdog would pull it back, a visible wiggle. While a
/// vertical-dominant gesture (and its momentum) is in flight, the stack holds still.
///
/// A pure state machine fed by `WatchdogView`'s app-level scroll-wheel monitor, so the transitions
/// are testable without synthesizing `NSEvent`s.
@MainActor
final class WheelGestureTracker {
    /// The app-wide tracker, fed by a local scroll-wheel monitor it installs on first use.
    /// Tests build their own un-monitored instances and drive `ingest` directly.
    static let shared: WheelGestureTracker = {
        let tracker = WheelGestureTracker()
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            tracker.ingest(phase: event.phase, momentumPhase: event.momentumPhase,
                           dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                           window: event.window, locationInWindow: event.locationInWindow)
            return event
        }
        return tracker
    }()

    /// How long after the last wheel event the lock stays engaged. Events arrive at frame cadence
    /// through a drag and its momentum, so recency tells "still delivering" from "over"; `.ended`
    /// can't, since momentum may or may not follow it. Without it, a flick with no momentum would
    /// leave the lock on and defeat the next programmatic scroll (the drill's auto-scroll). It also
    /// segments phase-less devices: a quiet gap this long starts a fresh, undecided gesture.
    ///
    /// Cross-pane holds are handled by `shouldHoldHorizontalDrift(for:)`, not by this window;
    /// don't shorten it to paper over a scoping gap.
    static let staleness: TimeInterval = 0.1

    /// How much accumulated travel decides a gesture's axis. Not the first nonzero delta: a
    /// touch-down's opening samples are noisy (a vertical scroll can open with `dx:-2, dy:-1`), and
    /// one misread unlocks the whole gesture. Eight points is a few events into a real drag and far
    /// below anything that reads as scrolling.
    static let decisionTravel: CGFloat = 8

    private var verticalDominant = false
    private var decided = false
    /// Whether a gesture is open: a `.began` arrived or drag deltas are accumulating. Not the same
    /// as `!decided`, which also holds after momentum ends, when nothing may hold.
    private var holdEligible = false
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var lastEventAt: TimeInterval = 0
    /// Where the current gesture started: the window and location of its first attributable
    /// non-momentum event, frozen for the gesture's life (see `ingest`). `nil` when no event carried
    /// a window or that window is gone; `shouldHoldHorizontalDrift(for:)` treats both alike.
    private weak var gestureWindow: NSWindow?
    private var gestureLocation: NSPoint = .zero

    /// True while an in-flight gesture requires the stack to hold its horizontal position: it is
    /// vertical-dominant, or open and undecided, so a vertical scroll can't leak even its first
    /// frames. The cost is a `decisionTravel` dead zone at the start of a horizontal swipe, as in
    /// Finder.
    ///
    /// The unscoped answer, for anywhere in the app. A watchdog guarding one stack must ask
    /// `shouldHoldHorizontalDrift(for:)`: up to three stacks share one monitor, and an unscoped
    /// hold would revert one pane's reveal while another pane coasts.
    func shouldHoldHorizontalDrift(at now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        (verticalDominant || (!decided && holdEligible)) && now - lastEventAt < Self.staleness
    }

    /// The scoped answer a pane's watchdog asks: hold only when a hold-worthy gesture is in flight
    /// and it started within `view`'s stack. A gesture with no attribution holds everywhere, so a
    /// vertical gesture still can't drift its own stack when scoping has nothing to go on.
    ///
    /// Containment is against the enclosing scroll view, not the clip, whose bounds exclude the
    /// scroller band under "Show scroll bars: Always" and would hold nothing there. The scroll view
    /// is what receives the deltas a column forwards up, so only gestures inside it can leak in.
    /// Views with no enclosing scroll view (unit fixtures) use their own bounds.
    func shouldHoldHorizontalDrift(for view: NSView,
                                   at now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard shouldHoldHorizontalDrift(at: now) else { return false }
        guard let window = gestureWindow else { return true }
        let container = view.enclosingScrollView ?? view
        guard container.window === window else { return false }
        return container.bounds.contains(container.convert(gestureLocation, from: nil))
    }

    /// Feed one scroll-wheel event's fields. A `.began` phase, or a quiet gap on phase-less
    /// devices, starts a fresh, undecided gesture; drag deltas accumulate until `decisionTravel`
    /// picks the axis; momentum inherits the decision and never makes one. The decision clears when
    /// momentum ends, the gesture cancels, or a new one begins.
    ///
    /// A plain mouse wheel's events carry no phase at all, so nothing would ever clear and the
    /// first click would latch the axis for the session, holding ⇧-wheel scrolls against the user.
    /// So each ungrouped event is its own gesture, decided from its own deltas, with no accumulation
    /// or undecided hold: a discrete click is deliberate, and a sub-threshold hold would leave a
    /// slow precision wheel permanently held.
    func ingest(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, dx: CGFloat, dy: CGFloat,
                window: NSWindow? = nil, locationInWindow: NSPoint = .zero,
                at now: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        if now - lastEventAt >= Self.staleness {
            reset()
        }
        lastEventAt = now
        if phase.contains(.began) {
            reset()
            holdEligible = true
        }
        let isUngrouped = phase.isEmpty && momentumPhase.isEmpty
        if isUngrouped {
            reset()
            if dx != 0 || dy != 0 {
                decided = true
                verticalDominant = abs(dy) > abs(dx)
            }
        } else if !decided, momentumPhase.isEmpty {
            holdEligible = true
            travelX += abs(dx)
            travelY += abs(dy)
            if max(travelX, travelY) >= Self.decisionTravel {
                decided = true
                verticalDominant = travelY > travelX
            }
        }
        // Attribution, once per gesture, from its first non-momentum event (`.began`, or an
        // ungrouped wheel click). After the resets, so a fresh gesture is attributed to where it
        // starts. Frozen, because AppKit routes a phased gesture to the view it began over
        // wherever the pointer goes: re-attributing would move the hold to another pane when a
        // Magic Mouse swipe drifts across, unguarding the first and blocking the second's reveal.
        if momentumPhase.isEmpty, gestureWindow == nil, let window {
            gestureWindow = window
            gestureLocation = locationInWindow
        }
        if momentumPhase.contains(.ended) || phase.contains(.cancelled) {
            reset()
        }
    }

    private func reset() {
        decided = false
        verticalDominant = false
        holdEligible = false
        travelX = 0
        travelY = 0
        // Attribution belongs to one gesture: clearing it here lets the next re-attribute, so the
        // freeze doesn't become a latch.
        gestureWindow = nil
        gestureLocation = .zero
    }
}

/// A pane's handle on the overscroll watchdog inside its own column stack, so the pane's reveal
/// can ask whether that stack is held by the axis lock. The scoped query needs a view inside the
/// stack, which the watchdog has and a SwiftUI `View` doesn't; the unscoped one would let a flick in
/// one pane defer the other's reveal.
///
/// Not `ObservableObject`: nothing here drives a re-render. A one-way pointer the watchdog
/// registers in, read once per reveal attempt.
@MainActor
final class PaneColumnHoldGate {
    /// `nonisolated` so `@State`'s initializer, which runs outside the actor, can build one.
    nonisolated init() {}

    /// The watchdog mounted in this pane's stack, re-registered on every SwiftUI update pass.
    /// Weak, so the gate can't keep a torn-down watchdog alive; `nil` reads as not held.
    fileprivate weak var watchdog: PaneColumnsOverscrollReturn.WatchdogView?

    /// Whether a hold-worthy wheel gesture is in flight inside this pane's own stack right now.
    var isStackHeld: Bool { watchdog?.isStackHeld ?? false }

    /// The one deferred reveal this pane is waiting on, so a second reveal replaces the first and a
    /// teardown has something to cancel.
    ///
    /// Several drivers schedule reveals (`browsePath`, the preview's rising edge, either stored
    /// width growing, in both panes for the `@AppStorage` column width), each with two attempts that
    /// re-check while the stack is held. Unbounded, repeated drills would leave parallel polling
    /// chains, each retaining the pane's captures and `ScrollViewProxy` past the pane's life. An
    /// `asyncAfter` block can't be cancelled or tied to a `View`, so the handle lives here.
    private var pendingReveal: RevealBody?

    /// Which reveal this pane is running. Bumped by `beginReveal` and `cancelPendingReveal`, so
    /// anything holding an older number has been superseded.
    ///
    /// Each reveal also issues two plain `DispatchQueue.main` attempts (`.async` and
    /// `.asyncAfter(+revealRetryDelay)`) that can't be cancelled. Without the counter, one already
    /// queued could park a chain after teardown, or an older reveal's retry could replace a newer
    /// reveal's chain, aimed at the `treeRoot` snapshotted into its closure. A queued block can't
    /// be told, so it has to ask.
    private var generation = 0

    /// The parked chain's body, in a box the gate can empty. Cancelling a `DispatchWorkItem` isn't
    /// enough: libdispatch keeps a scheduled item, and its captures, alive until its deadline.
    /// Dropping the closure releases them at once; the queue keeps only the empty box.
    /// `testAPaneParksOneDeferredRevealAndDropsTheRest` fails on the `DispatchWorkItem` version.
    private final class RevealBody {
        var run: (@MainActor () -> Void)?
    }

    /// Opens a new reveal: drops whatever is parked, supersedes every attempt still queued by an
    /// earlier reveal, and returns the number the new reveal's attempts must carry. Called at the
    /// top of `revealDeepestColumn`.
    @discardableResult
    func beginReveal() -> Int {
        dropPending()
        generation += 1
        return generation
    }

    /// Whether `generation` is still the reveal this pane is running. False once a later reveal has
    /// begun or a teardown has cancelled.
    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// Whether a chain is parked right now, so a test can act once a reveal starts waiting instead
    /// of racing its retry on the wall clock.
    var hasPendingReveal: Bool { pendingReveal?.run != nil }

    /// Parks `body` as this pane's pending reveal, `delay` from now, dropping whatever was parked,
    /// unless `generation` has been superseded: then nothing is parked or disturbed. That refusal
    /// makes a cancel final and a fresh reveal authoritative, and lives in the gate so no caller
    /// can forget it.
    func deferReveal(generation: Int, by delay: TimeInterval,
                     _ body: @escaping @MainActor () -> Void) {
        guard isCurrent(generation) else { return }
        dropPending()
        let parked = RevealBody()
        parked.run = body
        pendingReveal = parked
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let run = parked.run else { return }
                // Released before the call: a body that parks the next link must not be held by the
                // link that ran it.
                parked.run = nil
                run()
            }
        }
    }

    /// Drops the pending reveal and supersedes the reveal that parked it: pane teardown.
    ///
    /// A parked chain reads `browsePath` live but carries the `treeRoot` it was scheduled with, so
    /// after a re-root it would aim at an id no column carries. The generation bump makes the cancel
    /// final: a reveal's queued attempts can't be cancelled, and without it one could still scroll
    /// and park a fresh chain after the pane is gone.
    func cancelPendingReveal() {
        dropPending()
        generation += 1
    }

    /// Releases the parked chain's captures without touching the generation: the half of a cancel
    /// that `beginReveal` and `deferReveal` also need.
    private func dropPending() {
        pendingReveal?.run = nil
        pendingReveal = nil
    }
}

/// Returns the column stack from an overscrolled position when the platform fails to.
///
/// The stack is a horizontal `ScrollView` of `List`s, nested scroll views. Wheel events over a
/// column are forwarded up to the stack for the horizontal axis, and that loses the gesture's
/// phase, so the stack never sees "gesture ended", the signal AppKit's rubber band springs back
/// on. An overscrolled stack would stay stretched until some unrelated event, like the pointer
/// leaving the pane. Signals such as `didEndLiveScroll` come through the same broken channel.
///
/// So this watches state, not signals. Every bounds change of the stack's own clip view re-arms
/// a short timer, which never fires while anything moves. When the stack rests, it fires once and
/// animates the stack home if it rests out of range. A working native bounce settles in range,
/// so the watchdog never fights the platform.
///
/// A zero-size `.background` inside the horizontal `ScrollView`, so the ancestor walk finds that
/// scroll view, not a column's (whose document is an `NSTableView`).
struct PaneColumnsOverscrollReturn: NSViewRepresentable {
    /// This pane's handle on the watchdog mounted below (see `PaneColumnHoldGate`). `nil` for
    /// suites that build a `WatchdogView` directly.
    var holdGate: PaneColumnHoldGate?

    func makeNSView(context: Context) -> WatchdogView {
        let view = WatchdogView()
        view.holdGate = holdGate
        return view
    }
    /// A SwiftUI update can rebuild the scroll view under us, so re-resolve every pass. The gate is
    /// re-attached too: a remount hands the pane a new `WatchdogView`, and a gate on the old one
    /// would answer for a stack no longer on screen.
    func updateNSView(_ view: WatchdogView, context: Context) {
        view.holdGate = holdGate
        view.rearm()
    }

    final class WatchdogView: BoundedResolveView {
        /// The gesture-axis lock the snap consults. `.shared` in the app; tests inject their own
        /// and drive it directly.
        var axisLock: WheelGestureTracker = .shared

        /// How long the pull home takes. Injectable for tests (see "The machine decides the
        /// verdict — throttled CoreAnimation" in `docs/flaky-tests.md`): the pull is an implicit
        /// CoreAnimation animation, which a starved machine never advances in an offscreen window,
        /// so a test waiting for home would time out. Zero means no animation at all; a
        /// zero-duration group still defers through CoreAnimation and starves the same way.
        ///
        /// The default is pinned by `thePullHomeShipsAnimated`, since every test injects zero and
        /// a default drifted to zero would silently remove the bounce.
        var pullDuration: TimeInterval = WatchdogView.defaultPullDuration

        /// What the app ships: long enough to read as a bounce, short enough not to feel like a
        /// correction.
        static let defaultPullDuration: TimeInterval = 0.25
        /// The pane's handle on this watchdog, so `PaneColumnsView.revealDeepestColumn` can ask
        /// the scoped hold question before it scrolls. Assigned by the representable.
        var holdGate: PaneColumnHoldGate? {
            didSet { holdGate?.watchdog = self }
        }
        /// The stack's horizontal rest, updated on every bounds change outside a vertical-dominant
        /// gesture. While one is in flight, the stack is held here and any drift reverted to it.
        private var restX: CGFloat = 0
        private weak var observedScroller: NSScrollView?
        /// The scroll view being guarded, exposed so a mounted test can check the walk found the
        /// stack's scroll view, not a column's.
        var resolvedScroller: NSScrollView? { observedScroller }
        private var observers: [NSObjectProtocol] = []
        /// Coalesces the quiescence re-arm, which runs at frame cadence through a scroll (see
        /// `QuiescenceTimer`). `Self.quiescence`, how long the stack must rest before the check,
        /// lives on `BoundedResolveView`, shared with the column probe's timer.
        private lazy var quiesce = QuiescenceTimer(quiescence: Self.quiescence)
        private var pendingHold: DispatchWorkItem?

        override func windowDidExit() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedScroller = nil
            quiesce.cancel()
            pendingHold?.cancel()
            pendingHold = nil
        }

        /// Runs from every layout pass and from `rearm()`'s deferred hop; layout also catches
        /// out-of-range states no gesture made (a column closing at the far end). Only arms a
        /// timer: the correction never runs inside a layout pass.
        override func resolvePass() {
            resolveAndObserve()
            scheduleCheck()
        }

        private func resolveAndObserve() {
            guard window != nil else { return }
            if let observedScroller, observedScroller.window === window, !observers.isEmpty { return }
            guard spendSearchBudget() else { return }
            guard let scroller = Self.findStackScrollView(from: self) else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            let clip = scroller.contentView
            clip.postsBoundsChangedNotifications = true
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.holdAgainstVerticalGestureLeak()
                        self?.scheduleCheck()
                    }
                }
            ]
            observedScroller = scroller
            restX = clip.bounds.origin.x
        }

        /// Whether a hold-worthy wheel gesture is in flight in this stack: the question
        /// `holdAgainstVerticalGestureLeak` asks, exposed so a reveal can ask before it scrolls
        /// rather than have its scroll reverted. False while nothing is resolved, since with no
        /// scroller there is no revert either.
        var isStackHeld: Bool {
            guard let scroller = observedScroller else { return false }
            return axisLock.shouldHoldHorizontalDrift(for: scroller.contentView)
        }

        /// The axis lock's enforcement: while a vertical-dominant gesture is in flight, leaked
        /// horizontal drift is reverted by `enforceHold()`. Otherwise this only keeps `restX`
        /// current.
        ///
        /// **Never** revert from in here. This runs inside the bounds-change notification, and
        /// `setBoundsOrigin` posts that notification synchronously before the origin reads as set,
        /// so an inline revert recurses until the stack overflows (a SwiftUI animated scroll
        /// mid-gesture triggers it). Handlers only schedule. The coalesced hop also limits a fight
        /// with a SwiftUI scroll to one revert per runloop turn, until the lock's recency lapses.
        private func holdAgainstVerticalGestureLeak() {
            guard let scroller = observedScroller else { return }
            // Scoped to this stack's clip, so a flick in one pane can't revert another pane's
            // reveal; the gesture's own pane still holds.
            guard axisLock.shouldHoldHorizontalDrift(for: scroller.contentView) else {
                restX = scroller.contentView.bounds.origin.x
                return
            }
            guard pendingHold == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingHold = nil
                self?.enforceHold()
            }
            pendingHold = work
            DispatchQueue.main.async(execute: work)
        }

        /// Puts the stack back on `restX`, outside any notification context. Re-checks the lock:
        /// if it lapsed during the hop, this does nothing, not even adopt the drifted position.
        /// Adopting here would bake a late-enforced leak in as the new rest, and every later hold
        /// would defend it; adoption is the observer's job.
        private func enforceHold() {
            guard let scroller = observedScroller else { return }
            let clip = scroller.contentView
            guard axisLock.shouldHoldHorizontalDrift(for: clip) else { return }
            guard clip.bounds.origin.x != restX else { return }
            clip.setBoundsOrigin(NSPoint(x: restX, y: clip.bounds.origin.y))
            scroller.reflectScrolledClipView(clip)
        }

        /// Re-arms the quiescence timer. Called on every bounds change and layout pass, so the check
        /// runs only once the stack stops, and must be cheap: `QuiescenceTimer` makes it a
        /// timestamp write while a timer is in flight.
        private func scheduleCheck() {
            guard observedScroller != nil else { return }
            quiesce.noteActivity { [weak self] in self?.returnHomeIfStranded() }
        }

        private func returnHomeIfStranded() {
            guard let scroller = observedScroller else { return }
            let clip = scroller.contentView
            let origin = clip.bounds.origin
            let home = Self.legalOrigin(for: origin, clip: clip)
            guard max(abs(home.x - origin.x), abs(home.y - origin.y)) >= Self.tolerance else { return }
            // Every pull is logged, with fractions so a sub-point correction loop can't hide as
            // "pull (0, 0) → (0, 0)". Gated like the sibling probes: an ungated per-frame line
            // would flood the 1000-entry log buffer.
            if PaneScrollTrace.isEnabled {
                Logger.shared.debug(String(
                    format: "[stack] pull (%.2f, %.2f) → (%.2f, %.2f), doc %.1f×%.1f clip %.1f×%.1f",
                    origin.x, origin.y, home.x, home.y,
                    clip.documentView?.frame.width ?? -1, clip.documentView?.frame.height ?? -1,
                    clip.bounds.width, clip.bounds.height))
            }
            if pullDuration > 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = pullDuration
                    context.allowsImplicitAnimation = true
                    clip.setBoundsOrigin(home)
                }
            } else {
                // Straight to the answer, with no animation to be starved of ticks.
                clip.setBoundsOrigin(home)
            }
            scroller.reflectScrolledClipView(clip)
        }

        /// The nearest enclosing scroll view that is not a column's list. Checks `documentView`
        /// (a column's is its `NSTableView`) rather than the subtree, because the stack's document
        /// contains tables and a subtree search would call it a column.
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
