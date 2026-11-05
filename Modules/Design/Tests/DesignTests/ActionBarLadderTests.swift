import Testing
import SwiftUI
import AppKit
@testable import Design

/// Pins the one SwiftUI layout fact the Differences header's shedding ladder rests on: a
/// `ViewThatFits` whose candidate rows contain a `Spacer` still advances down the ladder as the
/// proposed width shrinks.
///
/// Worth a test because the intuition cuts the other way: a Spacer is infinitely flexible, so it
/// looks as though any row could squeeze into any width and strand the header on its widest
/// candidate. It doesn't, because a Spacer's ideal width is its `minLength`, giving each candidate
/// a finite ideal. If an SDK changed that, the header would silently stop shedding and clip.
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
        // A bare `Spacer()` sheds identically: its default minLength is the platform spacing, not
        // zero. `standardHeaderRow`'s minLength guarantees a visible seam between the scope and
        // action zones; the ladder doesn't depend on it.
        #expect(chosenRungHeight(width: 400, spacerMinLength: nil) == 40)
        #expect(chosenRungHeight(width: 200, spacerMinLength: nil) == 20)
    }
}
