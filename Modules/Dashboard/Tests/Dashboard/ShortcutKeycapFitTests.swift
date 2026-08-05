import AppKit
import Design
import SwiftUI
import Testing
@testable import Dashboard

/// The shortcut key has to fit the tightest control that wears one.
///
/// It lives here rather than in Design because Design cannot see `PaneNavMetrics`, and the number
/// that matters is the nav pill's — the pane search magnifier is the smallest badged control in the
/// app by a wide margin, and the key is centred on it.
///
/// This exists because the key was made deliberately larger once, for legibility, and the only
/// thing standing between "more visible" and "overlapping the button next to it" is that the pill
/// happens to be wide enough. That is a fact about two numbers in two modules, so it gets a test
/// rather than a comment.
@MainActor
@Suite struct ShortcutKeycapFitTests {

    /// The widest symbol any adopter passes to a nav-pill-sized control.
    private static let widestNavSymbol = "⌘F"

    @Test func theKeyFitsTheNavPillItIsCentredOn() {
        let key = NSHostingView(rootView: ShortcutKeycap(Self.widestNavSymbol)).fittingSize
        let pill = PaneNavMetrics.pill(.regular)

        // The key may overhang the pill, but never by more than HALF the gap to the next control.
        // Half, not all of it: two adjacent badged controls each overhang toward each other, so a
        // full-gap allowance lets them meet in the middle. Measured today — a 30pt key on a 33pt
        // pill does not overhang at all, so this has 3pt of headroom before it binds.
        //
        // A whole-gap allowance was the first version of this rule and it did not bind: bumping the
        // key a further size step, which is exactly the regression this exists to catch, passed it.
        let overhangPerSide = (key.width - pill.width) / 2
        #expect(overhangPerSide <= PaneNavMetrics.pairSpacing / 2,
                "a \(key.width)pt key on a \(pill.width)pt pill overhangs \(overhangPerSide)pt per side, over half the \(PaneNavMetrics.pairSpacing)pt gap to the next control")
    }

    /// ...and the same at the mini control size, which the compact pane header uses.
    @Test func theKeyFitsTheMiniNavPillToo() {
        let key = NSHostingView(rootView: ShortcutKeycap(Self.widestNavSymbol)).fittingSize
        let pill = PaneNavMetrics.pill(.mini)
        // The tighter of the two, and the one that actually constrains the key's size: 27pt of
        // pill against a 30pt key, so 1.5pt of overhang per side against a 3pt allowance.
        let overhangPerSide = (key.width - pill.width) / 2
        #expect(overhangPerSide <= PaneNavMetrics.pairSpacing / 2,
                "mini: a \(key.width)pt key on a \(pill.width)pt pill overhangs \(overhangPerSide)pt per side")
    }
}
