import AppKit
import SwiftUI

/// The shared skeleton of the pane's "bounded ancestor-search" helper views — the zero-size
/// `.background` siblings that must reach an AppKit neighbour SwiftUI hands them no reference to:
/// `PaneColumnJitterProbe` and `PaneColumnsOverscrollReturn` (the two watchdogs, which resolve a
/// scroll view and observe its clip), and `PaneListSelectionStyler` /
/// `DifferencesTableSelectionStyler` (the two stylers, which resolve a table through
/// `PaneListResolver` — see `FrameAnchoredResolveView` below), and `PaneBackgroundDeselect`
/// (frame-anchored like the stylers, installing a gesture recognizer rather than styling). This
/// used to be five private copies of one discipline.
///
/// The discipline, in one place:
///
/// - **`viewDidMoveToWindow`.** Leaving the window tears the copy's observers and timers down
///   (`windowDidExit()`) — there rather than in `deinit`, because a nonisolated `deinit` cannot
///   touch non-Sendable stored state. Entering one re-arms explicitly: an earlier styler released
///   its observers on exit and never re-attached on re-entry.
/// - **`layout()`.** Every pass re-runs `resolvePass()`, because SwiftUI re-tiles and can rebuild
///   the neighbour under us on data changes or tab switches.
/// - **`rearm()`.** A SwiftUI update (`updateNSView`) refills the search budget and retries after
///   the current runloop turn — the neighbour's scroll view may not exist yet while SwiftUI is
///   still mounting this background view, so the deferred pass is what catches the mount.
/// - **The budget.** `layout()` runs the search on every pass, so a hierarchy the search can never
///   resolve — the steady state if a future macOS reshapes SwiftUI's List — would otherwise burn a
///   full ancestor scan per layout pass, on both panes, forever. `searchesPerChange` bounds that
///   burst, and `spendSearchBudget()` is the one guarded decrement. What refills it is each copy's
///   correctness story: the watchdogs refill only on `rearm()`, the frame-anchored three — both
///   stylers and the deselect catcher — also on the anchor moving or a resolved table ceasing to
///   be theirs (see `FrameAnchoredResolveView`).
///
/// Subclasses supply exactly two things: `resolvePass()` — resolve the neighbour if needed, then
/// do the copy's work — and `windowDidExit()`. Everything else is owned here so the five cannot
/// drift apart again.
class BoundedResolveView: NSView {
    /// How many ancestor searches one change buys — THE budget constant, in its one home.
    /// `PaneColumnJitterProbe` used to re-declare this as a bare `4`, and
    /// `PaneColumnsOverscrollReturn` as a private twin; both now inherit this default. The
    /// frame-anchored three — both stylers and the deselect catcher — walk a wider hierarchy and
    /// override it to 6.
    class var searchesPerChange: Int { 4 }

    /// How long a watched clip must rest before a watchdog's check runs. Long enough that a
    /// momentum tail's sparse deltas (frame-cadence, ~16ms apart) keep deferring it; short enough
    /// that the return reads as a bounce, not a correction.
    ///
    /// Owned here because BOTH watchdogs feed it to their `QuiescenceTimer` — the column probe
    /// used to reach across into `PaneColumnsOverscrollReturn.WatchdogView` for it. (The
    /// frame-anchored three have no quiescence timer; the constant sits with the shared base
    /// rather than making either watchdog reach into the other.)
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
    ///
    /// Owned here for `quiescence`'s reason, and it is the same pair of readers: both watchdogs
    /// compare their resting origin against it, and the column probe used to reach across into
    /// `PaneColumnsOverscrollReturn.WatchdogView` for this one and for `legalOrigin` below. (The
    /// frame-anchored three watch no clip at all; the constants sit with the shared base rather
    /// than making either watchdog reach into the other.)
    static let tolerance: CGFloat = 2

    /// The nearest legal resting origin. Static and internal so the clamp can be pinned
    /// directly; the mounted tests drive the whole watchdog.
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
    ///
    /// Shared with `tolerance` above, and for the same reason: the stack watchdog clamps its
    /// horizontal rest with it and the column probe clamps its vertical one, and neither should
    /// be reaching into the other for the rule.
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

    /// The remaining burst budget. Starts full, so a copy resolved before its first `rearm()`
    /// (tests drive `layout()` directly) behaves exactly as the five private copies did.
    private lazy var searchBudget: Int = Self.searchesPerChange

    /// Spends one search if any remain. The caller's fast path ("still resolved and still in this
    /// window") must run BEFORE this — a resolved copy costs nothing per pass.
    final func spendSearchBudget() -> Bool {
        guard searchBudget > 0 else { return false }
        searchBudget -= 1
        return true
    }

    /// Back to a full burst — a change signal arrived (SwiftUI update, window entry, or a styler's
    /// anchor-moved / lost-its-table re-arm).
    final func refillSearchBudget() { searchBudget = Self.searchesPerChange }

    /// Whether the burst ran dry — the styler ladder's steady-state trigger.
    final var searchBudgetIsSpent: Bool { searchBudget == 0 }

    /// One search, granted by the stylers' steady-state drip: a table swapped in place beneath a
    /// perfectly still anchor is what no change signal can see.
    final func grantOneSearch() { searchBudget = 1 }

    /// `final`, like `layout()` below, because this is the seam and not a hook. Before the
    /// consolidation each of the five copies owned this method outright; now a subclass that
    /// overrides it and forgets `super` silently disables the whole budget / re-arm / teardown
    /// discipline for that copy — and on `PaneBackgroundDeselect` that has no visible symptom at
    /// all, it just quietly stops deselecting (see that file). Sealing it costs nothing: the
    /// intended hooks are `resolvePass()`, `windowDidExit()` and `rearm()`, and no subclass
    /// overrode either of these two.
    final override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return windowDidExit() }
        rearm()
    }

    /// Teardown on the way out of the window: observers, timers, pending work. Base does nothing;
    /// each copy releases exactly what it holds.
    func windowDidExit() {}

    /// `final` for `viewDidMoveToWindow`'s reason: an override that forgot `super` here would stop
    /// every copy's per-pass re-resolve, which is what catches a neighbour SwiftUI rebuilt under us.
    final override func layout() {
        super.layout()
        resolvePass()
    }

    /// Refills the budget and retries after the current runloop turn. Called by the
    /// representable's `updateNSView` (a SwiftUI update can mean a rebuilt neighbour) and on
    /// window entry.
    func rearm() {
        refillSearchBudget()
        DispatchQueue.main.async { [weak self] in self?.resolvePass() }
    }

    /// One resolve-and-apply pass — the single override point the skeleton drives from `layout()`
    /// and from `rearm()`'s deferred hop. Must be cheap when already resolved: it runs per layout
    /// pass.
    func resolvePass() {}
}

/// The frame-anchored variant the two selection stylers and the deselect catcher share: resolves an
/// `NSTableView` through
/// `PaneListResolver` (the frame IS the identity — see that type), re-validates the cached answer
/// on every pass, and re-arms the budget on the two signals that genuinely mean "the list under me
/// may have changed".
///
/// **What re-arms it is the whole correctness story.** The budget used to re-arm on a SwiftUI
/// update — i.e. on `updateNSView` — and that quietly meant "constantly", because the host
/// re-rendered the pane on every one of its ~56 published properties. The styler was being
/// spammed, and the spam was doing the work: any table SwiftUI recreated got re-styled within
/// milliseconds because the budget had just been refilled again.
///
/// Then `FileTreeView` became `Equatable` (`cbc1eca`) and the pane stopped re-rendering on
/// unrelated state — correctly — and this went with it. Once the budget hit zero, nothing
/// refilled it, the styler gave up **permanently**, and the OS selection highlight came back
/// underneath the pane's own accent wash: a bright blue row where the table had key focus,
/// a gray one where it did not, and the app's teal only on the lists that happened to
/// resolve before the budget ran out. Three different-looking selections in one window.
///
/// So it re-arms on the two things that genuinely mean "the list under me may have changed":
/// the anchor moving, and a table we had ceasing to be ours. Neither depends on how often
/// SwiftUI updates us, which is the property that was missing. `passesSinceExhausted` then
/// covers what no change signal can see — a table swapped in place beneath a perfectly still
/// anchor — at a thirtieth of the cost of scanning every pass. The budget bounds a BURST; the
/// drip bounds the STEADY STATE. "Gave up permanently" is the defect all of this exists to
/// prevent, so it must not be reachable by any path.
class FrameAnchoredResolveView: BoundedResolveView {
    /// The frame-anchored walk scans up to six ancestor subtrees (see
    /// `PaneListResolver.searchDepth`), wider than the watchdogs' plain superview climb.
    override class var searchesPerChange: Int { 6 }

    /// Which kind of table the resolver should match: the pane stylers anchor to a single-column
    /// `List` backing; the differences styler to the one multi-column `Table`.
    class var resolvesMultiColumnTable: Bool { false }

    /// The anchor's window rect at the last search. A moved or resized anchor sits over a
    /// different list than it did — see `PaneListResolver`, where the frame IS the identity.
    private var lastSearchedTarget: CGRect = .null
    /// Layout passes since the burst budget ran dry with nothing found — the steady-state drip.
    private var passesSinceExhausted = 0
    private static let retryEveryNPasses = 30

    /// Test seam: how many ancestor scans have actually run. The re-arm rules are only
    /// meaningful if the STEADY state stays rare, and a suite with no way to count scans could
    /// not tell "recovers" from "scans on every single pass", which is the cost the budget
    /// exists to prevent.
    private(set) var searchesPerformed = 0

    /// The current answer. Readable by subclasses (the differences styler paints from it);
    /// written only by the ladder below.
    private(set) weak var cachedTable: NSTableView?

    /// Called whenever `table` is confirmed current — on a cached hit and on a fresh resolve —
    /// so a subclass with observers to attach has one hook for both paths. Base does nothing.
    func tableIsCurrent(_ table: NSTableView) {}

    /// Drops the cached answer without touching the budget or the ladder counters — for a
    /// subclass whose window exit invalidates its claim on the table
    /// (`PaneBackgroundDeselect` uninstalls its recognizer there and clears the cache with it).
    /// Equivalent to the `cachedTable = nil` those copies did by hand; the setter is private so
    /// the ladder stays the only writer on the resolve path.
    final func forgetResolvedTable() { cachedTable = nil }

    /// Re-validates a cached table against this view's current frame instead of trusting it for
    /// the lifetime of the window. A drill rebuilds the column stack wholesale, so a table that
    /// was this list's a moment ago can belong to a different column now — see
    /// `PaneListResolver` for why the frame is the identifier.
    /// Internal, not private: this is the test seam. The re-arm rules above are the whole
    /// correctness story and a suite that could not drive them would be asserting nothing.
    func resolveTableView() -> NSTableView? {
        guard window != nil else { return nil }
        let target = convert(bounds, to: nil)
        // Not laid out yet. Spending budget here would burn the search on a frame SwiftUI has
        // not assigned, and the retry would find none left.
        guard !target.isEmpty else { return nil }
        if let cached = cachedTable, cached.window === window,
           PaneListResolver.matches(cached, target: target) {
            tableIsCurrent(cached)
            return cached
        }
        // Reaching here means either we never had a table, or the one we had is gone or is no
        // longer the list under this anchor. The latter two are hierarchy changes and earn a
        // fresh budget; so does the anchor having moved. Sitting still with nothing to find
        // earns nothing, which is what keeps the bound meaningful. See the class doc.
        let anchorMoved = !target.equalTo(lastSearchedTarget)
        let lostItsTable = cachedTable != nil
        lastSearchedTarget = target
        // Cleared before the checks below, so `lostItsTable` reads true exactly once per
        // invalidation rather than on every later pass — otherwise a table that vanished for
        // good would refill the budget forever and reinstate the per-layout scan.
        cachedTable = nil
        if anchorMoved || lostItsTable {
            refillSearchBudget()
            passesSinceExhausted = 0
        } else if searchBudgetIsSpent {
            passesSinceExhausted += 1
            if passesSinceExhausted >= Self.retryEveryNPasses {
                passesSinceExhausted = 0
                grantOneSearch()
            }
        }
        guard spendSearchBudget() else { return nil }
        searchesPerformed += 1
        cachedTable = PaneListResolver.table(matching: self,
                                             multiColumn: Self.resolvesMultiColumnTable)
        if let table = cachedTable { tableIsCurrent(table) }
        return cachedTable
    }
}
