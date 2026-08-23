import AppKit
import Events
import SwiftUI

/// Which axis the current wheel gesture belongs to, decided once per gesture from accumulated
/// early deltas — the axis lock Finder's column view applies.
///
/// Why it exists: a "vertical" trackpad scroll is never purely vertical. Its small horizontal
/// components leak through the column list to the stack (per-event responder forwarding, the
/// same channel that loses gesture phase), and with two or more columns open the stack is live —
/// so every vertical scroll nudged the stack sideways a few points, the drift parked in
/// overscroll, and the watchdog animated it back: a repeating sideways wiggle reported as
/// "jitter when a 2nd column is open". Locking the gesture to its dominant axis stops the leak
/// at the root: while a vertical-dominant gesture (and its momentum) is in flight, the stack
/// holds still.
///
/// Pure state machine, fed by `WatchdogView`'s app-level scroll-wheel monitor; separated so the
/// transitions are unit-testable without synthesizing `NSEvent`s.
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

    /// How long after the last wheel event the lock stays engaged. Events arrive at frame
    /// cadence throughout a drag AND its momentum, so recency is what distinguishes "gesture
    /// still delivering deltas" from "gesture over, nothing followed" — the `.ended` event
    /// itself cannot, because momentum may or may not arrive after it. Without this, a vertical
    /// flick that produced no momentum left the lock engaged and quietly defeated the next
    /// programmatic scroll (the drill's own auto-scroll after a click). The same window also
    /// SEGMENTS phase-less devices: a mouse wheel's events carry no `.began`, so a quiet gap
    /// longer than this starts a fresh, undecided gesture.
    ///
    /// Recency is a TIMING answer to what was partly a SCOPING problem: shortening this window
    /// once stood in for the fact that a gesture in one pane held every pane's stack. The
    /// cross-pane half is now solved properly — `shouldHoldHorizontalDrift(for:)` holds only
    /// the pane the gesture is inside — so this window's remaining job is the same-pane one
    /// described above, and it must not be shortened further to paper over a scoping gap again.
    static let staleness: TimeInterval = 0.1

    /// How much accumulated travel decides a gesture's axis. Deciding on the FIRST nonzero
    /// delta shipped and misfired: a trackpad touch-down's opening samples are directionally
    /// noisy (a vertical scroll can open with `dx:-2, dy:-1`), and one misread unlocked the
    /// whole gesture — the stack drifted, parked, and got pulled back on every few scrolls,
    /// reported as "the 1st column flickers". Eight points of evidence is a few events into a
    /// real drag and far below anything that reads as scrolling distance.
    static let decisionTravel: CGFloat = 8

    private var verticalDominant = false
    private var decided = false
    /// Whether a gesture is genuinely OPEN — a `.began` arrived or drag deltas are
    /// accumulating. Distinct from `!decided`, because "undecided" also describes the state
    /// after momentum finished, and nothing must hold then: end-of-momentum is definitive.
    private var holdEligible = false
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var lastEventAt: TimeInterval = 0
    /// Where the current gesture STARTED: the window and in-window location of the first
    /// attributable non-momentum event since the gesture began. Written once per gesture and
    /// frozen for its life — see `ingest`. `nil` means the gesture has no attribution: no event
    /// carried a window (a test driving `ingest` without one), or the window it was attributed to
    /// has since been torn down. Those two are deliberately NOT distinguished; both mean scoping
    /// has nothing to go on, and `shouldHoldHorizontalDrift(for:)` treats them alike.
    private weak var gestureWindow: NSWindow?
    private var gestureLocation: NSPoint = .zero

    /// True while an in-flight gesture requires the stack to hold its horizontal position:
    /// the gesture is vertical-dominant, or it is open but has not yet earned a verdict — an
    /// undecided opening is held too, so a vertical scroll cannot leak even its first frames.
    /// The cost is a `decisionTravel`-sized dead zone at the start of a horizontal swipe, which
    /// is how Finder's own axis lock feels.
    ///
    /// This is the UNSCOPED answer — "is a hold-worthy gesture in flight anywhere in the app".
    /// A watchdog guarding one pane's stack must ask `shouldHoldHorizontalDrift(for:)` instead:
    /// there are up to three column stacks alive at once (two comparison panes and the Tidy
    /// rail), and one app-wide monitor feeds them all, so an unscoped hold in pane B during a
    /// vertical flick in pane A reverted B's own programmatic reveal — the deepest column
    /// stayed hidden whenever the other pane happened to be coasting.
    func shouldHoldHorizontalDrift(at now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        (verticalDominant || (!decided && holdEligible)) && now - lastEventAt < Self.staleness
    }

    /// The scoped answer a pane's watchdog asks: hold only when a hold-worthy gesture is in
    /// flight AND that gesture STARTED within `view`'s stack.
    ///
    /// A gesture with no attribution holds EVERYWHERE, which is the pre-scoping behavior: the
    /// original leak — a vertical gesture drifting its own pane's stack sideways — must stay
    /// fixed even when scoping has nothing to go on. That covers both an event that carried no
    /// window and a window torn down mid-gesture, and the two are deliberately treated alike:
    /// a distinction neither branch acts on is a comment describing code that does not exist.
    ///
    /// Containment is measured against the enclosing SCROLL VIEW, not the clip. The clip's bounds
    /// exclude the band the horizontal scroller occupies under "Show scroll bars: Always", so a
    /// gesture whose pointer sat on that strip was inside no pane's clip and held nothing —
    /// fail-CLOSED, which brought the original vertical-leak drift straight back for that band.
    /// The scroll view is the principled line as well as the practical one: it is precisely what
    /// receives the deltas a column's list forwards up, so a gesture anywhere it covers can leak
    /// into this stack, and one outside it (the pinned preview column, the pane's own chrome)
    /// cannot. Views with no enclosing scroll view — the tracker's own unit fixtures — fall back
    /// to their own bounds.
    func shouldHoldHorizontalDrift(for view: NSView,
                                   at now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard shouldHoldHorizontalDrift(at: now) else { return false }
        guard let window = gestureWindow else { return true }
        let container = view.enclosingScrollView ?? view
        guard container.window === window else { return false }
        return container.bounds.contains(container.convert(gestureLocation, from: nil))
    }

    /// Feed one scroll-wheel event's fields. A `.began` phase — or a quiet gap on phase-less
    /// devices — starts a fresh, undecided gesture; drag deltas accumulate until
    /// `decisionTravel` of evidence picks the axis; momentum events inherit the decision (they
    /// never make one — their direction is history, not intent). The decision clears when
    /// momentum finishes, the gesture cancels, or a new gesture begins.
    ///
    /// A traditional (non-Magic) mouse wheel groups nothing: its events carry no `.began`, no
    /// momentum and no `.ended`, so none of those clears would ever fire and the FIRST wheel
    /// click of the session would latch the axis for the rest of it. Latched vertical, the lock
    /// then reported "in flight" within its recency window of every later wheel event and
    /// `enforceHold` reverted the stack — so a ⇧-wheel horizontal scroll of the column stack was
    /// held against the user, permanently, on any mouse without a touch surface. An ungrouped
    /// event therefore decides for ITSELF, from its own deltas alone: with no phase to group
    /// them, each wheel click *is* its own gesture — and neither the accumulation nor the
    /// undecided-hold applies to it, because a discrete click is deliberate where a touch-down
    /// is noisy, and a sub-threshold hold would leave a slow precision wheel permanently held.
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
        // Attribution: ONCE per gesture, from its first attributable non-momentum event —
        // `.began` for a trackpad, the event itself for an ungrouped wheel click (each of which
        // is its own gesture, and has just reset above). Placed after the resets so a fresh
        // gesture is attributed to where it starts, not to whatever the last one left behind.
        //
        // Frozen for the gesture's life, because AppKit routes a phased gesture to the view it
        // BEGAN over regardless of where the pointer goes next. Re-attributing on every
        // `.changed` therefore migrated the hold on any device whose pointer can move during the
        // gesture: a Magic Mouse vertical swipe started over pane A and drifting into pane B
        // silently unguarded A — which promptly started drifting sideways, the original jitter
        // bug — and held B instead, defeating B's own programmatic reveal. Momentum's wandering
        // pointer is the same failure a beat later and is excluded by the same freeze, plus the
        // `momentumPhase.isEmpty` test: its deltas are history, not intent.
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
        // Attribution belongs to ONE gesture: clearing it here is what makes the next gesture
        // re-attribute, and what makes the freeze above a freeze rather than a latch.
        gestureWindow = nil
        gestureLocation = .zero
    }
}

/// A pane's handle on the overscroll watchdog mounted inside its own column stack, so the pane's
/// reveal can ask whether THAT stack is currently held by the axis lock.
///
/// Why a handle at all, rather than asking `WheelGestureTracker.shared` outright: the lock is
/// app-wide and the question is per-pane. Only `shouldHoldHorizontalDrift(for:)` scopes it, and
/// that needs a view inside the stack in question — which a SwiftUI `View` does not have and the
/// watchdog does. Asking the UNSCOPED query instead would make a flick in one pane defer the other
/// pane's reveal, re-creating from the reveal's side exactly the cross-pane coupling the scoped
/// query was added to remove.
///
/// Deliberately not `ObservableObject`: nothing here drives a re-render. It is a one-way pointer
/// the watchdog registers itself in, read once per reveal attempt.
@MainActor
final class PaneColumnHoldGate {
    /// `nonisolated` so `@State`'s initializer — which runs outside the actor — can build one.
    nonisolated init() {}

    /// The watchdog mounted in this pane's stack, re-registered on every SwiftUI update pass.
    /// Weak, so a torn-down pane's watchdog cannot be kept alive by its gate; `nil` reads as NOT
    /// held, which is what the reveal did before this existed.
    fileprivate weak var watchdog: PaneColumnsOverscrollReturn.WatchdogView?

    /// Whether a hold-worthy wheel gesture is in flight inside this pane's own stack right now.
    var isStackHeld: Bool { watchdog?.isStackHeld ?? false }

    /// The ONE deferred reveal this pane is waiting on — so a second reveal REPLACES the first
    /// rather than adding to it, and so a teardown has something to cancel.
    ///
    /// Four drivers schedule a reveal (`browsePath`, the preview's rising edge, and each of the two
    /// stored widths growing — and the column width is `@AppStorage`, so it fires in BOTH panes),
    /// each schedules two attempts, and each attempt that finds the stack held re-checks on its own
    /// timer. Drilling three times inside one hold therefore left six independent chains polling at
    /// 10Hz. They were never in DISAGREEMENT — every attempt re-resolves its target live, so the
    /// newest chain says everything an older one would — only redundant, and redundancy here is
    /// paid for in retention: each chain strongly holds the pane's captures (its tree, its indices,
    /// its delegate and closures) plus the `ScrollViewProxy` until it expires, including after the
    /// pane is gone. A `DispatchQueue.main.asyncAfter` block is neither cancellable nor tied to
    /// view lifetime, which is precisely why the cancellable has to live somewhere that outlives a
    /// single `View` value — here.
    private var pendingReveal: RevealBody?

    /// Which reveal this pane is currently running. Bumped by `beginReveal` and by
    /// `cancelPendingReveal`, so anything still holding an older number has been superseded.
    ///
    /// The parked chain is only half of what a reveal leaves behind. The other half is the two
    /// plain `DispatchQueue.main` attempts every reveal issues — a `.async` and a
    /// `.asyncAfter(+revealRetryDelay)` — and those are neither cancellable nor tied to view
    /// lifetime, which is the same property that forced the cancellable onto this gate in the first
    /// place. Emptying the box therefore did not make a cancel FINAL: an attempt already queued
    /// when the pane was torn down still ran, and could park a fresh chain after `.onDisappear` had
    /// cancelled. Nor did the entry cancel make a fresh reveal authoritative: a previous reveal's
    /// 0.25s retry, queued and unstoppable, fired afterwards and replaced the new reveal's chain
    /// with its own — at a reset budget, and aiming at the `treeRoot` it had been scheduled with
    /// (a stored `let` snapshotted into the closure; only `browsePath` is read live). So the case
    /// the parking was meant to close — a re-root's reveal dropping the chain still aiming at the
    /// old root — was closed only for chains parked BEFORE the re-root.
    ///
    /// A counter closes both, because both are the same mistake: work from a reveal that no longer
    /// speaks for this pane. Held here rather than passed around because a queued block is exactly
    /// what cannot be told; it has to ask.
    private var generation = 0

    /// The parked chain's body, in a box the gate can EMPTY.
    ///
    /// Cancelling a `DispatchWorkItem` is not enough and measuring it is what showed that:
    /// libdispatch keeps a scheduled item alive until its deadline arrives whether or not it has
    /// been cancelled, so the cancelled block went on holding the pane for the whole remaining
    /// budget — exactly the retention this machinery exists to bound, surviving the cancel that was
    /// supposed to end it. Dropping the closure out of the box releases the captures on the spot;
    /// what the queue keeps until the deadline is then this empty box, and the block it drains into
    /// finds nothing to run. `testAPaneParksOneDeferredRevealAndDropsTheRest` fails on the
    /// `DispatchWorkItem` version.
    private final class RevealBody {
        var run: (@MainActor () -> Void)?
    }

    /// Opens a new reveal: drops whatever is parked, supersedes every attempt still queued by an
    /// earlier reveal, and returns the number the new reveal's attempts must carry.
    ///
    /// Called at the top of `revealDeepestColumn`, where `cancelPendingReveal` used to be.
    @discardableResult
    func beginReveal() -> Int {
        dropPending()
        generation += 1
        return generation
    }

    /// Whether `generation` is still the reveal this pane is running. False once a later reveal has
    /// begun or a teardown has cancelled.
    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// Whether a chain is parked right now. The seam a test needs to act at the moment a reveal has
    /// begun waiting — the alternative is racing the reveal's own 0.25s retry off the wall clock.
    var hasPendingReveal: Bool { pendingReveal?.run != nil }

    /// Parks `body` as THIS pane's pending reveal, `delay` from now, dropping whatever was parked
    /// before — unless `generation` has been superseded, in which case nothing is parked and
    /// nothing already parked is disturbed.
    ///
    /// The refusal is what makes a cancel final and a fresh reveal authoritative. A superseded
    /// attempt that parked would reinstate a chain the teardown had just dropped, or evict the
    /// live reveal's chain in favour of an older reveal's; either way the gate would be holding
    /// work for a reveal that no longer speaks for this pane. Refusing here rather than only at the
    /// call site keeps that a property of the gate, so a future caller cannot forget it.
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
                // Released before the call, not after: a body that parks the next link of the chain
                // must not be held by the link that ran it.
                parked.run = nil
                run()
            }
        }
    }

    /// Drops the pending reveal and supersedes the reveal that parked it — pane teardown.
    ///
    /// Superseding matters beyond the retention: a parked chain re-resolves `browsePath` live but
    /// carries the `treeRoot` it was scheduled with, so a re-root while it waits leaves it aiming
    /// at an id no rendered column carries. Dropping it in favour of the re-root's own reveal is
    /// what keeps the waiting chain speaking for the stack that exists.
    ///
    /// The generation bump is what makes this FINAL rather than merely current. A reveal's two
    /// attempts are queued blocks that cannot be cancelled, so `.onDisappear` emptying the box left
    /// an attempt from inside the last `revealRetryDelay` free to run, scroll, and park a fresh
    /// chain after the pane was gone. That self-limited — a torn-down watchdog reports no scroller,
    /// so the gate reads not-held and the scroll goes to a dead proxy — but the bound came from the
    /// fail-open path rather than from the cancel, and the re-ask above now lives a cadence longer
    /// than it used to. After this, the cancel itself is the bound.
    func cancelPendingReveal() {
        dropPending()
        generation += 1
    }

    /// Releases the parked chain's captures without touching the generation — the half of a cancel
    /// that `beginReveal` and `deferReveal` also need.
    private func dropPending() {
        pendingReveal?.run = nil
        pendingReveal = nil
    }
}

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
    /// This pane's handle on the watchdog mounted below — see `PaneColumnHoldGate`. `nil` for the
    /// synthetic suites that build a `WatchdogView` directly.
    var holdGate: PaneColumnHoldGate?

    func makeNSView(context: Context) -> WatchdogView {
        let view = WatchdogView()
        view.holdGate = holdGate
        return view
    }
    /// A SwiftUI update can rebuild the scroll view under us, so re-resolve rather than trusting
    /// one pass. The gate is re-attached on every pass for the same reason: a remount hands the
    /// pane a different `WatchdogView`, and a gate still pointing at the old one would answer for
    /// a stack that is no longer on screen.
    func updateNSView(_ view: WatchdogView, context: Context) {
        view.holdGate = holdGate
        view.rearm()
    }

    final class WatchdogView: NSView {
        /// The gesture-axis lock the snap consults. `.shared` in the app; tests inject their own
        /// and drive it directly.
        var axisLock: WheelGestureTracker = .shared

        /// How long the pull home takes. Injectable for the same reason `axisLock` is, and for the
        /// reason `docs/flaky-tests.md` mechanism 1 gives: the pull is an implicit CoreAnimation
        /// animation, and the tests mount an offscreen, never-key window. When CoreAnimation is
        /// starved — display asleep, Low Power Mode, or simply a full parallel test run — that
        /// animation never advances, so `clip.bounds.origin` never reaches home and a test waiting
        /// on it burns its whole timeout and reports the START state. Measured: this suite failed
        /// three times in one afternoon under load (22.8 s to give up) and passed 3/3 isolated in
        /// 1.4 s, twice locally and once in CI.
        ///
        /// Zero means "no animation at all", not "a very fast one" — a zero-duration group still
        /// defers through CoreAnimation and can be starved exactly the same way.
        ///
        /// **The default is pinned by a test** (`thePullHomeShipsAnimated`), because once every
        /// test in the suite injects zero, nothing reads the value the app actually ships and a
        /// default that drifted to zero would delete the bounce for real users in silence.
        var pullDuration: TimeInterval = WatchdogView.defaultPullDuration

        /// What the app ships: long enough to read as a bounce, short enough not to feel like a
        /// correction.
        static let defaultPullDuration: TimeInterval = 0.25
        /// The pane's handle on this watchdog, so `PaneColumnsView.revealDeepestColumn` can ask
        /// the scoped hold question before it scrolls. Assigned by the representable.
        var holdGate: PaneColumnHoldGate? {
            didSet { holdGate?.watchdog = self }
        }
        /// The stack's horizontal rest, updated on every bounds change made OUTSIDE a
        /// vertical-dominant gesture. While one is in flight, this is the position the stack is
        /// held at — the leak-snap below reverts any drift straight back to it.
        private var restX: CGFloat = 0
        private weak var observedScroller: NSScrollView?
        /// The scroll view the watchdog is currently guarding — exposed so the mounted test can
        /// assert the ancestor walk resolved the STACK's scroll view and not a column's list.
        var resolvedScroller: NSScrollView? { observedScroller }
        private var observers: [NSObjectProtocol] = []
        /// Coalesces the quiescence re-arm. This used to cancel and allocate a fresh
        /// `DispatchWorkItem` on every bounds-change notification — i.e. at frame cadence for the
        /// whole length of a scroll — to answer one question at the end of it. See `QuiescenceTimer`.
        private lazy var quiesce = QuiescenceTimer(quiescence: Self.quiescence)
        private var pendingHold: DispatchWorkItem?
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
            quiesce.cancel()
            pendingHold?.cancel()
            pendingHold = nil
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
                    MainActor.assumeIsolated {
                        self?.holdAgainstVerticalGestureLeak()
                        self?.scheduleCheck()
                    }
                }
            ]
            observedScroller = scroller
            restX = clip.bounds.origin.x
        }

        /// Whether a hold-worthy wheel gesture is in flight in THIS stack right now — the exact
        /// question `holdAgainstVerticalGestureLeak` asks before it schedules a revert, exposed so
        /// the pane's reveal can ask it BEFORE it scrolls rather than discovering the answer as a
        /// reverted scroll it never retries.
        ///
        /// False while nothing is resolved yet: with no observed scroller there is no revert
        /// either, so a reveal has nothing to lose by going ahead — the same fail-open the reveal
        /// had before this existed.
        var isStackHeld: Bool {
            guard let scroller = observedScroller else { return false }
            return axisLock.shouldHoldHorizontalDrift(for: scroller.contentView)
        }

        /// The axis lock's enforcement: while a vertical-dominant wheel gesture is in flight, the
        /// stack holds its horizontal position — drift from the gesture's leaked horizontal
        /// deltas is reverted by `enforceHold()`. Outside such a gesture this only keeps `restX`
        /// current.
        ///
        /// **The revert must never run from in here.** This executes inside the bounds-change
        /// notification, and `setBoundsOrigin` posts that same notification SYNCHRONOUSLY, at a
        /// point where the origin does not yet read as the value being set — so a revert made
        /// on the spot re-enters itself and recurses until the stack guard kills the app
        /// (shipped, crashed at recursion level 1839, triggered by SwiftUI starting its own
        /// animated scroll mid-gesture). Same rule the quiescence timer already followed:
        /// handlers only *schedule*; mutation happens outside notification context. The
        /// coalesced hop also bounds any fight with a SwiftUI-driven scroll at one revert per
        /// runloop turn, and the lock's 100ms recency ends even that.
        private func holdAgainstVerticalGestureLeak() {
            guard let scroller = observedScroller else { return }
            // Scoped to THIS stack's clip: an app-wide lock held every pane's stack, so a
            // vertical flick in one pane (its momentum keeping the lock fresh) made the OTHER
            // pane's watchdog revert that pane's own programmatic reveal — the deepest column
            // stayed hidden. The gesture's own pane must still hold, and does: the lock
            // answers true exactly for the clip the gesture is inside.
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

        /// Puts the stack back on `restX`, outside any notification context. Re-checks the lock
        /// at execution time: if it lapsed during the hop, the moment has passed and this does
        /// NOTHING — including not adopting the drifted position. Adoption is the observer's
        /// job, on bounds changes made outside a lock; adopting here bakes a leak in as the new
        /// rest whenever enforcement lands late (a loaded main thread pushed it past the
        /// recency window), and every later hold then defends the leaked position.
        private func enforceHold() {
            guard let scroller = observedScroller else { return }
            let clip = scroller.contentView
            guard axisLock.shouldHoldHorizontalDrift(for: clip) else { return }
            guard clip.bounds.origin.x != restX else { return }
            clip.setBoundsOrigin(NSPoint(x: restX, y: clip.bounds.origin.y))
            scroller.reflectScrolledClipView(clip)
        }

        /// Re-arms the quiescence timer. Called on every bounds change AND on every layout pass, so
        /// the check only ever runs once the stack has actually stopped moving — and so it must be
        /// cheap to call. `QuiescenceTimer` makes it a timestamp write while a timer is already in
        /// flight, instead of the cancel-and-reallocate this used to do per notification.
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
            // Every pull is logged — fractional, because `%.0f` is exactly how a sub-point
            // correction loop hid as "pull (0, 0) → (0, 0)" for a night of 18,000 lines.
            // Gated like the sibling probes: that night is also what an UNGATED per-frame line
            // does to the 1000-entry buffer, so the trace flag is the price of seeing it.
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
