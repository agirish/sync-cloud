import AppKit
import Testing
@testable import FileExplorer

/// Pins the constants the five bounded-resolve views share through `BoundedResolveView`, so a
/// drift in the one definition — or a subclass quietly re-declaring its own — is a named failure
/// rather than a silent behavior change in every subclass at once.
///
/// **The declaration pins below are not enough on their own, which is why the behavioural ones
/// follow them.** `#expect(StylerView.searchesPerChange == 6)` asserts what the subclass
/// *declares*; it says nothing about which declaration the base's own code reads. Every one of
/// them would still pass if `refillSearchBudget()` were changed to read
/// `BoundedResolveView.searchesPerChange` rather than `Self.searchesPerChange` — at which point
/// the two stylers and the deselect catcher would silently drop to a budget of 4, walking a
/// six-deep hierarchy with four searches, and no test in this file would name it. `Self.` on a
/// `class var` IS dynamically dispatched today, so that is a missing pin rather than a live bug;
/// the spend-the-budget tests below are what would catch it becoming one.
@MainActor
@Suite struct BoundedResolveViewTests {

    /// The two watchdogs inherit the base budget; the probe's old bare literal `4` and the stack
    /// watchdog's private twin are both this one constant now.
    @Test func theWatchdogsShareTheBaseSearchBudget() {
        #expect(BoundedResolveView.searchesPerChange == 4)
        #expect(PaneColumnJitterProbe.ProbeView.searchesPerChange == 4)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.searchesPerChange == 4)
    }

    /// The frame-anchored resolvers walk a wider hierarchy (see `PaneListResolver.searchDepth`)
    /// and carry the wider budget — one override, inherited by all three.
    @Test func theFrameAnchoredResolversShareTheWiderBudget() {
        #expect(FrameAnchoredResolveView.searchesPerChange == 6)
        #expect(PaneListSelectionStyler.StylerView.searchesPerChange == 6)
        #expect(DifferencesTableSelectionStyler.StylerView.searchesPerChange == 6)
        #expect(PaneBackgroundDeselect.CatcherView.searchesPerChange == 6)
    }

    /// `quiescence` is owned by the base — the column probe used to reach across into the stack
    /// watchdog for it. Both watchdogs must keep reading the same interval, at the value the
    /// pull-home behavior was tuned for.
    @Test func quiescenceIsOwnedByTheBaseAndShared() {
        #expect(BoundedResolveView.quiescence == 0.14)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.quiescence
                    == BoundedResolveView.quiescence)
        #expect(PaneColumnJitterProbe.ProbeView.quiescence == BoundedResolveView.quiescence)
    }

    /// `tolerance` and `legalOrigin` moved to the base for `quiescence`'s exact reason: the column
    /// probe was still reaching across into `PaneColumnsOverscrollReturn.WatchdogView` for both of
    /// them after `quiescence` had stopped. Same file pair, same coupling, half-removed.
    ///
    /// The values are the ones the pull-home was tuned for and must not move with the ownership —
    /// `tolerance` is the loop-breaker that ended the 18,000-pull night, and `legalOrigin`'s
    /// document-frame band is what makes a fitting document's home its leading edge rather than 0.
    @Test func theClipClampIsOwnedByTheBaseAndShared() {
        #expect(BoundedResolveView.tolerance == 2)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance == BoundedResolveView.tolerance)
        #expect(PaneColumnJitterProbe.ProbeView.tolerance == BoundedResolveView.tolerance)

        // A document narrower than its clip: the legal band collapses to the leading edge, which is
        // the case a zero-based clamp got wrong. One answer, whichever subclass is asked.
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
    /// a real `StylerView` and count what it bought. Six spends, then the seventh is refused — the
    /// guarded decrement in `spendSearchBudget()` is the bound, and 6 is what the base must have
    /// read when it refilled.
    ///
    /// `refillSearchBudget()` is called explicitly rather than relying on the lazy initial value,
    /// because that initializer reads the constant too — a test that only exercised a fresh
    /// instance would be blind to the refill path, which is the one that runs on every window
    /// entry, every SwiftUI update, and every anchor move for the rest of the session.
    @Test func aStylersRefillBuysSixSearches() {
        let styler = PaneListSelectionStyler.StylerView()
        styler.refillSearchBudget()
        #expect(spendsAvailable(to: styler) == 6)
    }

    /// The deselect catcher is the copy whose exhausted budget has NO visible symptom — no
    /// recognizer is installed and clicking empty space silently stops deselecting — so its bound
    /// is worth asserting on the object rather than on its metatype. See `PaneBackgroundDeselect`.
    @Test func theDeselectCatchersRefillBuysSixSearches() {
        let catcher = PaneBackgroundDeselect.CatcherView(onDeselect: {})
        catcher.refillSearchBudget()
        #expect(spendsAvailable(to: catcher) == 6)
    }

    /// The other direction, and the one that makes the pair a discriminator rather than a
    /// restatement: the watchdogs climb plain superviews and must keep the narrower 4. A base that
    /// stopped dispatching would hand every copy the same number, so both halves have to be read.
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
    /// of hanging the run — `docs/flaky-tests.md` mechanism 8.
    private func spendsAvailable(to view: BoundedResolveView, cap: Int = 100) -> Int {
        var granted = 0
        for _ in 0..<cap where view.spendSearchBudget() { granted += 1 }
        return granted
    }
}
