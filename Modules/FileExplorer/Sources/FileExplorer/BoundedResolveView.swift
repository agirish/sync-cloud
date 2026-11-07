import AppKit
import SwiftUI

/// The shared skeleton of the pane's bounded ancestor-search helpers: zero-size `.background`
/// siblings that must reach an AppKit neighbour SwiftUI gives them no reference to. The two
/// watchdogs (`PaneColumnJitterProbe`, `PaneColumnsOverscrollReturn`) resolve a scroll view and
/// observe its clip; the two stylers (`PaneListSelectionStyler`, `DifferencesTableSelectionStyler`)
/// and `PaneBackgroundDeselect` resolve a table through `PaneListResolver`
/// (`FrameAnchoredResolveView` below).
///
/// The discipline, in one place:
///
/// - `viewDidMoveToWindow`: leaving the window tears observers and timers down
///   (`windowDidExit()`), there rather than in `deinit`, which is nonisolated and can't touch
///   non-Sendable state. Entering one re-arms explicitly, so a copy re-attaches on re-entry.
/// - `layout()`: every pass re-runs `resolvePass()`, because SwiftUI can rebuild the neighbour
///   under us on data changes or tab switches.
/// - `rearm()`: a SwiftUI update (`updateNSView`) refills the search budget and retries after the
///   current runloop turn, since the neighbour may not exist yet while SwiftUI is still mounting
///   this view.
/// - The budget: without it, a hierarchy the search can never resolve (a future macOS reshaping
///   SwiftUI's List) would cost a full ancestor scan per layout pass, on both panes, forever.
///   `searchesPerChange` bounds that burst and `spendSearchBudget()` is the one guarded decrement.
///   The watchdogs refill only on `rearm()`; the frame-anchored three also on the anchor moving or
///   a resolved table ceasing to be theirs.
///
/// Subclasses supply `resolvePass()` (resolve the neighbour if needed, then do the work) and
/// `windowDidExit()`. Everything else lives here so the copies can't drift apart.
class BoundedResolveView: NSView {
    /// How many ancestor searches one change buys. The frame-anchored three walk a wider hierarchy
    /// and override it to 6.
    class var searchesPerChange: Int { 4 }

    /// How long a watched clip must rest before a watchdog's check runs. Long enough that a
    /// momentum tail's sparse deltas (frame-cadence, ~16ms apart) keep deferring it; short enough
    /// that the return reads as a bounce, not a correction. Here, not in either watchdog, because
    /// both feed it to their `QuiescenceTimer`.
    static let quiescence: TimeInterval = 0.14

    /// How far out of range a resting origin must be before it is worth a pull.
    ///
    /// The loop-breaker, not an optimisation. SwiftUI parks the clip at fractional origins (pixel
    /// alignment on Retina), so a zero-tolerance watchdog would pull the origin to the legal point,
    /// SwiftUI would re-park it a fraction off, the bounds change would re-arm the timer, and the
    /// animated pull would repeat every quiescence interval forever, a visible shimmer. A
    /// stranding the eye can see is tens of points; anything under this must be left where SwiftUI
    /// put it. Here because both watchdogs compare their resting origin against it.
    static let tolerance: CGFloat = 2

    /// The nearest legal resting origin. Static and internal so the clamp can be pinned directly;
    /// the mounted tests drive the whole watchdog.
    ///
    /// Measured from the document's frame, not from zero: when the document is wider than the clip
    /// the legal band is [minX, maxX − clipWidth], and when it is narrower (three columns in a wide
    /// pane) the band collapses to the leading edge, where SwiftUI parks fitting content. A
    /// zero-based clamp would get that wrong and pull forever (see `tolerance`). Content insets
    /// widen the band, since an inset clip legally rests at a negative origin (`-insets.top`); the
    /// pane's clips have zero insets today, so that part is armor. Shared because the stack
    /// watchdog clamps its horizontal rest with it and the column probe its vertical one.
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
    /// (tests drive `layout()` directly) still gets its burst.
    private lazy var searchBudget: Int = Self.searchesPerChange

    /// Spends one search if any remain. The caller's fast path ("still resolved and still in this
    /// window") must run before this, so a resolved copy costs nothing per pass.
    final func spendSearchBudget() -> Bool {
        guard searchBudget > 0 else { return false }
        searchBudget -= 1
        return true
    }

    /// Back to a full burst: a change signal arrived (SwiftUI update, window entry, or a styler's
    /// anchor-moved or lost-its-table re-arm).
    final func refillSearchBudget() { searchBudget = Self.searchesPerChange }

    /// Whether the burst ran dry: the styler ladder's steady-state trigger.
    final var searchBudgetIsSpent: Bool { searchBudget == 0 }

    /// One search, granted by the stylers' steady-state drip: a table swapped in place beneath a
    /// perfectly still anchor is what no change signal can see.
    final func grantOneSearch() { searchBudget = 1 }

    /// `final`, like `layout()` below, because this is the seam, not a hook. A subclass that
    /// overrode it and forgot `super` would silently disable the budget, re-arm and teardown for
    /// that copy; on `PaneBackgroundDeselect` it would just quietly stop deselecting. The intended
    /// hooks are `resolvePass()`, `windowDidExit()` and `rearm()`.
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

    /// One resolve-and-apply pass: the single override point, driven from `layout()` and from
    /// `rearm()`'s deferred hop. Must be cheap when already resolved: it runs per layout pass.
    func resolvePass() {}
}

/// The frame-anchored variant the two selection stylers and the deselect catcher share: resolves an
/// `NSTableView` through `PaneListResolver` (the frame is the identity; see that type),
/// re-validates the cached answer on every pass, and re-arms the budget on the two signals that
/// really mean "the list under me may have changed".
///
/// What re-arms it is the whole correctness story. Re-arming on SwiftUI updates works only while
/// the host re-renders constantly; `FileTreeView` is `Equatable` and doesn't, so a budget refilled
/// only by updates would run dry and the styler would give up permanently, letting the OS
/// selection highlight show under the pane's own accent wash (blue with key focus, grey without).
/// So it re-arms on the anchor moving and on a table we had ceasing to be ours, neither of which
/// depends on how often SwiftUI updates us. `passesSinceExhausted` covers what no change signal
/// can see, a table swapped in place beneath a still anchor, at a thirtieth of the cost of
/// scanning every pass. The budget bounds a burst; the drip bounds the steady state. Giving up
/// permanently must not be reachable by any path.
class FrameAnchoredResolveView: BoundedResolveView {
    /// The frame-anchored walk scans up to six ancestor subtrees (see
    /// `PaneListResolver.searchDepth`), wider than the watchdogs' plain superview climb.
    override class var searchesPerChange: Int { 6 }

    /// Which kind of table the resolver should match: the pane stylers anchor to a single-column
    /// `List` backing; the differences styler to the one multi-column `Table`.
    class var resolvesMultiColumnTable: Bool { false }

    /// The anchor's window rect at the last search. A moved or resized anchor sits over a
    /// different list than it did (`PaneListResolver`: the frame is the identity).
    private var lastSearchedTarget: CGRect = .null
    /// Layout passes since the burst budget ran dry with nothing found: the steady-state drip.
    private var passesSinceExhausted = 0
    private static let retryEveryNPasses = 30

    /// Test seam: how many ancestor scans have actually run, so a suite can tell "recovers" from
    /// "scans on every pass", the cost the budget exists to prevent.
    private(set) var searchesPerformed = 0

    /// The current answer. Readable by subclasses (the differences styler paints from it);
    /// written only by the ladder below.
    private(set) weak var cachedTable: NSTableView?

    /// Called whenever `table` is confirmed current, on a cached hit and on a fresh resolve, so a
    /// subclass with observers to attach has one hook for both paths. Base does nothing.
    func tableIsCurrent(_ table: NSTableView) {}

    /// Drops the cached answer without touching the budget or the ladder counters, for a subclass
    /// whose window exit invalidates its claim on the table (`PaneBackgroundDeselect` uninstalls
    /// its recognizer there). The setter is private so the ladder stays the only writer on the
    /// resolve path.
    final func forgetResolvedTable() { cachedTable = nil }

    /// Re-validates a cached table against this view's current frame instead of trusting it for
    /// the window's lifetime: a drill rebuilds the column stack, so a table that was this list's a
    /// moment ago can belong to another column now (`PaneListResolver`). Internal as the test seam
    /// for the re-arm rules above.
    func resolveTableView() -> NSTableView? {
        guard window != nil else { return nil }
        let target = convert(bounds, to: nil)
        // Not laid out yet. Spending budget here would burn the search on a frame SwiftUI hasn't
        // assigned, and the retry would find none left.
        guard !target.isEmpty else { return nil }
        if let cached = cachedTable, cached.window === window,
           PaneListResolver.matches(cached, target: target) {
            tableIsCurrent(cached)
            return cached
        }
        // Here, we never had a table, or ours is gone or no longer under this anchor. The latter
        // two are hierarchy changes and earn a fresh budget, as does the anchor moving. Sitting
        // still with nothing to find earns nothing, which keeps the bound meaningful.
        let anchorMoved = !target.equalTo(lastSearchedTarget)
        let lostItsTable = cachedTable != nil
        lastSearchedTarget = target
        // Cleared before the checks below, so `lostItsTable` reads true once per invalidation;
        // otherwise a table gone for good would refill the budget forever and bring back the
        // per-layout scan.
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
