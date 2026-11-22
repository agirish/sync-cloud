import CoreGraphics
import SwiftUI
import Testing
@testable import SyncCloud

/// The Vault's cards packed into columns, each under the shortest so far.
@Suite struct VaultMasonryTests {
    let layout = VaultMasonry(minColumnWidth: 270, spacing: 12)

    @Test func asManyColumnsAsFitSharingTheWidth() {
        #expect(layout.columns(for: 300).count == 1)
        #expect(layout.columns(for: 552).count == 2, "two at exactly 270 each and the gap")
        let three = layout.columns(for: 900)
        #expect(three.count == 3 && abs(three.width - 292) < 0.001)
    }

    /// SwiftUI asks a scroll view's content for its size with no bound on the width; that once
    /// trapped, converting infinity to a column count, the moment the Vault opened.
    @Test func aWidthWithoutBoundIsOneColumn() {
        #expect(layout.columns(for: .infinity) == (1, 270))
        #expect(layout.columns(for: .nan) == (1, 270))
        #expect(layout.columns(for: 0) == (1, 270))
        #expect(layout.placements(width: .infinity, heights: [100, 50]).origins.map(\.x) == [0, 0])
    }

    @Test func eachCardGoesUnderTheShortestColumnLeavingNoGap() {
        // Passports (tall), I-94 (short), Cases (medium), then licenses: under the short I-94s,
        // not on a new row below the tallest card as a grid would.
        let (origins, height) = layout.placements(width: 900, heights: [600, 200, 400, 150, 100])
        let columnX = origins.map(\.x)
        #expect(columnX[0] == 0 && columnX[1] == 304 && columnX[2] == 608, "the first row left to right")
        #expect(origins[3] == CGPoint(x: 304, y: 212), "under the shortest, the I-94s")
        #expect(origins[4] == CGPoint(x: 304, y: 374), "still the shortest after it")
        #expect(height == 600)
    }

    /// Folding a card makes it short; the columns come from its full size, so no card moves to
    /// another column, and the cards under it in its own column move up.
    @Test func foldingACardMovesNoCardToAnotherColumn() {
        // Rows per card (header and rows): passports 8, I-94s 3, cases 5, licenses 3, SSNs 3.
        let sizes: [CGFloat] = [8, 3, 5, 3, 3]
        let open: [CGFloat] = [500, 180, 300, 180, 180]
        // The passports folded to their header: as short as any card now.
        let folded: [CGFloat] = [40, 180, 300, 180, 180]
        let before = layout.placements(width: 900, heights: open, sizes: sizes).origins
        let after = layout.placements(width: 900, heights: folded, sizes: sizes).origins
        #expect(before.map(\.x) == after.map(\.x), "every card in the column it was in")
        // Chosen by their heights instead, the folded passports' column would take the next card.
        #expect(layout.placements(width: 900, heights: folded).origins.map(\.x) != before.map(\.x))
        #expect(layout.assignments(width: 900, sizes: sizes) == [0, 1, 2, 1, 2])
    }

    @Test func aTieGoesToTheLeftmostAndOneColumnStacksInOrder() {
        let (origins, height) = layout.placements(width: 300, heights: [100, 50, 70])
        #expect(origins.map(\.y) == [0, 112, 174])
        #expect(height == 244)
        #expect(layout.placements(width: 900, heights: []).height == 0)
        let tie = layout.placements(width: 552, heights: [100, 100, 10]).origins
        #expect(tie[2].x == 0, "both columns as tall: the left one")
    }
}

/// The layouts keep each pass's measurements; a card that grows on its own, with no change to which
/// cards there are, must still be measured again.
@MainActor @Suite struct VaultMasonryCacheTests {
    final class Box: ObservableObject { @Published var height: CGFloat = 100 }

    /// Observed by the card alone: the layout's container sees no change when it moves.
    struct Card: View {
        @ObservedObject var box: Box
        var body: some View { Color.clear.frame(height: box.height) }
    }

    private func hosted(_ content: some View) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: AnyView(content.frame(width: 300)))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 2000)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func settled(_ view: NSHostingView<AnyView>) async -> CGFloat {
        for _ in 0..<20 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    @Test func aCardThatGrowsIsMeasuredAgainInColumns() async {
        let box = Box()
        let view = hosted(VaultMasonry { Card(box: box); Color.clear.frame(height: 50) })
        #expect(await settled(view) == 162)
        box.height = 300
        #expect(await settled(view) == 362, "300, the gap and 50")
    }

    @Test func aRowThatGrowsIsMeasuredAgainInTwoUp() async {
        let box = Box()
        let view = hosted(VaultTwoUp(minColumnWidth: 200, spacing: 8, rowSpacing: 6) { Card(box: box); Color.clear.frame(height: 50) })
        #expect(await settled(view) == 156)
        box.height = 300
        #expect(await settled(view) == 356, "300, the line gap and 50")
    }
}
