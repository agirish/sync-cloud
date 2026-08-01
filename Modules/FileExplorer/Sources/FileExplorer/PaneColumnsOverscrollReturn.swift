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
        /// The gesture-axis lock the snap consults. `.shared` in the app; tests inject their own
        /// and drive it directly.
        var axisLock: WheelGestureTracker = .shared
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
