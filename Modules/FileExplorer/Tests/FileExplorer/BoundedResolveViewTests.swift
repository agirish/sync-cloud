import AppKit
import Testing
@testable import FileExplorer

/// Pins the constants the five bounded-resolve views share through `BoundedResolveView`, so a
/// drift in the one definition, or a subclass re-declaring its own, is a named failure.
///
/// The declaration pins alone aren't enough: `#expect(StylerView.searchesPerChange == 6)` checks
/// what the subclass declares, not what the base's code reads. If `refillSearchBudget()` read
/// `BoundedResolveView.searchesPerChange` instead of `Self.searchesPerChange`, the stylers and the
/// deselect catcher would drop to a budget of 4 on a six-deep hierarchy. The spend-the-budget
/// tests below catch that.
@MainActor
@Suite struct BoundedResolveViewTests {

    /// The two watchdogs inherit the base budget, one constant for both.
    @Test func theWatchdogsShareTheBaseSearchBudget() {
        #expect(BoundedResolveView.searchesPerChange == 4)
        #expect(PaneColumnJitterProbe.ProbeView.searchesPerChange == 4)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.searchesPerChange == 4)
    }

    /// The frame-anchored resolvers walk a wider hierarchy (see `PaneListResolver.searchDepth`)
    /// and carry the wider budget: one override, inherited by all three.
    @Test func theFrameAnchoredResolversShareTheWiderBudget() {
        #expect(FrameAnchoredResolveView.searchesPerChange == 6)
        #expect(PaneListSelectionStyler.StylerView.searchesPerChange == 6)
        #expect(DifferencesTableSelectionStyler.StylerView.searchesPerChange == 6)
        #expect(PaneBackgroundDeselect.CatcherView.searchesPerChange == 6)
    }

    /// `quiescence` is owned by the base. Both watchdogs must keep reading the same interval, at
    /// the value the pull-home behavior was tuned for.
    @Test func quiescenceIsOwnedByTheBaseAndShared() {
        #expect(BoundedResolveView.quiescence == 0.14)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.quiescence
                    == BoundedResolveView.quiescence)
        #expect(PaneColumnJitterProbe.ProbeView.quiescence == BoundedResolveView.quiescence)
    }

    /// `tolerance` and `legalOrigin` are owned by the base too, at the values the pull-home was
    /// tuned for: `tolerance` keeps the pull-home from looping, and `legalOrigin`'s document-frame
    /// band makes a fitting document's home its leading edge rather than 0.
    @Test func theClipClampIsOwnedByTheBaseAndShared() {
        #expect(BoundedResolveView.tolerance == 2)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance == BoundedResolveView.tolerance)
        #expect(PaneColumnJitterProbe.ProbeView.tolerance == BoundedResolveView.tolerance)

        // A document narrower than its clip: the legal band collapses to the leading edge, where a
        // zero-based clamp would be wrong. One answer, whichever subclass is asked.
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        scroller.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        let clip = scroller.contentView
        let stranded = NSPoint(x: -40, y: 0)
        let home = BoundedResolveView.legalOrigin(for: stranded, clip: clip)
        #expect(home == NSPoint(x: clip.documentView!.frame.minX, y: 0))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: stranded, clip: clip)
                    == home)
        #expect(PaneColumnJitterProbe.ProbeView.legalOrigin(for: stranded, clip: clip) == home)
    }

    // MARK: The budget the base's own code actually reads

    /// The behavioural half of `theFrameAnchoredResolversShareTheWiderBudget`: spend the budget on
    /// a real `StylerView` and count what it bought. Six spends, then the seventh is refused: the
    /// guarded decrement in `spendSearchBudget()` is the bound, and 6 is what the base must have
    /// read when it refilled.
    ///
    /// `refillSearchBudget()` is called explicitly, not left to the initial value, so the refill
    /// path is covered: it runs on every window entry, SwiftUI update and anchor move.
    @Test func aStylersRefillBuysSixSearches() {
        let styler = PaneListSelectionStyler.StylerView()
        styler.refillSearchBudget()
        #expect(spendsAvailable(to: styler) == 6)
    }

    /// The deselect catcher's exhausted budget has no visible symptom (no recognizer is installed,
    /// and clicking empty space silently stops deselecting), so its bound is asserted on the
    /// object, not the metatype. See `PaneBackgroundDeselect`.
    @Test func theDeselectCatchersRefillBuysSixSearches() {
        let catcher = PaneBackgroundDeselect.CatcherView(onDeselect: {})
        catcher.refillSearchBudget()
        #expect(spendsAvailable(to: catcher) == 6)
    }

    /// The other direction, which makes the pair a discriminator: the watchdogs climb plain
    /// superviews and must keep the narrower 4. A base that stopped dispatching would hand every
    /// copy the same number.
    @Test func theWatchdogsRefillsBuyFourSearchesEach() {
        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        watchdog.refillSearchBudget()
        #expect(spendsAvailable(to: watchdog) == 4)

        let probe = PaneColumnJitterProbe.ProbeView()
        probe.refillSearchBudget()
        #expect(spendsAvailable(to: probe) == 4)
    }

    /// Drains a view's burst budget and reports what it held. Bounded rather than
    /// `while spendSearchBudget()`, so a budget that stopped decrementing fails this test instead
    /// of hanging the run (`docs/flaky-tests.md`, "The wait that hangs instead of failing").
    private func spendsAvailable(to view: BoundedResolveView, cap: Int = 100) -> Int {
        var granted = 0
        for _ in 0..<cap where view.spendSearchBudget() { granted += 1 }
        return granted
    }
}
