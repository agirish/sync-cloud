import AppKit
import Design
import SwiftUI
import Testing
@testable import Dashboard

/// The shortcut key has to fit the tightest control that wears one.
///
/// Here rather than in Design because Design can't see `PaneNavMetrics`, and the nav pill (the pane
/// search magnifier) is by far the smallest badged control. Whether a larger key overlaps the
/// button next to it depends on two numbers in two modules, so it gets a test.
@MainActor
@Suite struct ShortcutKeycapFitTests {

    /// The widest symbol any adopter passes to a nav-pill-sized control.
    private static let widestNavSymbol = "⌘F"

    /// The key may overhang the pill by at most half the gap to the next control: two adjacent
    /// badged controls overhang toward each other, so a whole-gap allowance lets them meet, and
    /// wouldn't catch the key growing a size step. Mini, which the compact pane header uses, is the
    /// tighter: a 27pt pill against a 30pt key, 1.5pt of overhang per side against a 3pt allowance.
    @Test(arguments: [ControlSize.regular, .mini])
    func theKeyFitsTheNavPillItIsCentredOn(size: ControlSize) {
        let key = NSHostingView(rootView: ShortcutKeycap(Self.widestNavSymbol)).fittingSize
        let pill = PaneNavMetrics.pill(size)
        let overhangPerSide = (key.width - pill.width) / 2
        #expect(overhangPerSide <= PaneNavMetrics.pairSpacing / 2,
                "\(size): a \(key.width)pt key on a \(pill.width)pt pill overhangs \(overhangPerSide)pt per side, over half the \(PaneNavMetrics.pairSpacing)pt gap to the next control")
    }
}
