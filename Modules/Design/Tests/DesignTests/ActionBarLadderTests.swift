import Testing
import SwiftUI
import AppKit
@testable import Design

/// Pins the one SwiftUI layout fact the Differences header's shedding ladder rests on: a
/// `ViewThatFits` whose candidate rows contain a `Spacer` still advances down the ladder as the
/// proposed width shrinks.
///
/// This is worth a test rather than a comment because the intuition cuts the other way — a Spacer
/// is infinitely *flexible*, so it reads as though it would let any row squeeze into any width and
/// strand the header on its widest candidate forever. It doesn't: a Spacer's ideal width is its
/// `minLength`, so each candidate reports a finite ideal that `ViewThatFits` can compare. If a
/// future SDK changed that, the header would silently stop shedding and start clipping instead —
/// which is exactly the failure this ladder was built to end.
@Suite struct ActionBarLadderTests {

    /// Lays out a two-rung ladder at `width` and reports which rung was chosen. The rungs differ
    /// in height so the answer is readable from the laid-out size rather than from private state.
    @MainActor
    private func chosenRungHeight(width: CGFloat, spacerMinLength: CGFloat?) -> CGFloat {
        func rung(contentWidth: CGFloat, height: CGFloat) -> some View {
            HStack(spacing: 0) {
                Color.clear.frame(width: contentWidth / 2, height: height)
                if let spacerMinLength { Spacer(minLength: spacerMinLength) } else { Spacer() }
                Color.clear.frame(width: contentWidth / 2, height: height)
            }
        }
        let root = ViewThatFits(in: .horizontal) {
            rung(contentWidth: 300, height: 40)     // wide rung
            rung(contentWidth: 100, height: 20)     // narrow rung
        }
        .frame(width: width)
        let host = NSHostingView(rootView: root)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    @Test func testLadderTakesTheWidestRungThatFits() {
        // Room for the wide rung (300 + a 16pt gap): it wins.
        #expect(chosenRungHeight(width: 400, spacerMinLength: 16) == 40)
    }

    @MainActor
    @Test func testLadderAdvancesWhenTheWidestRungNoLongerFits() {
        // The header's whole premise. A Spacer inside a candidate does NOT make it fit everywhere.
        #expect(chosenRungHeight(width: 200, spacerMinLength: 16) == 20)
        #expect(chosenRungHeight(width: 120, spacerMinLength: 16) == 20)
    }

    @MainActor
    @Test func testTheMinimumGapDoesNotDecideWhetherTheLadderWorks() {
        // A bare `Spacer()` sheds identically — its default minLength is the platform spacing, not
        // zero. `standardHeaderRow` states a minLength to guarantee a visible seam between the
        // scope and action zones, not to make the ladder function; recording that here so the
        // constant doesn't acquire a load-bearing reputation it hasn't earned.
        #expect(chosenRungHeight(width: 400, spacerMinLength: nil) == 40)
        #expect(chosenRungHeight(width: 200, spacerMinLength: nil) == 20)
    }
}
