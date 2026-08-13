import AppKit
import Testing
@testable import FileExplorer

/// Pins the constants the four bounded-resolve views share through `BoundedResolveView`, so a
/// drift in the one definition — or a subclass quietly re-declaring its own — is a named failure
/// rather than a silent behavior change in every subclass at once.
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
}
