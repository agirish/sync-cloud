import Testing
import Foundation
@testable import FileExplorer
import Sync

/// ``TreemapView/visibleWidths(_:floorLastTile:available:visibleBytes:)`` — the arithmetic that
/// decides how wide each tile is drawn.
///
/// The invariant worth having is not any single width but that **they add up**: an `HStack` of
/// fixed-width children does not compress, and the `GeometryReader` around it does not clip, so
/// any overshoot is painted straight past the card's right edge. The straggler floor was applied
/// by widening the last tile in place, without taking the extra from anyone — the row was already
/// sized to fill the space, so the floor was pure overflow.
@Suite @MainActor struct TreemapWidthTests {

    static func nodes(_ bytes: [Int]) -> [TreemapNode] {
        bytes.enumerated().map { TreemapNode(name: "n\($0.offset)", path: "", bytes: $0.element) }
    }

    static func sum(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) }

    /// The reported case: two large folders and one sliver, with the sliver floored.
    @Test func aFlooredStragglerIsPaidForOutOfItsSiblings() {
        let bytes = [10_000, 8_000, 100]
        let available: CGFloat = 900
        let widths = TreemapView.visibleWidths(Self.nodes(bytes), floorLastTile: true,
                                               available: available,
                                               visibleBytes: bytes.reduce(0, +))
        #expect(widths.count == 3)
        #expect(abs(Self.sum(widths) - available) < 0.001,
                "the tiles sum to \(Self.sum(widths)) in a row of \(available) — the excess is drawn past the card")
        // The floor was actually applied, or this test is measuring the ordinary case.
        #expect(widths[2] >= TreemapView.labelMinWidth,
                "the straggler was not floored, so this fixture cannot see the defect")
        // And the siblings kept their proportions relative to each other.
        #expect(abs(widths[0] / widths[1] - 10_000.0 / 8_000.0) < 0.001)
    }

    /// Without the floor — a tail is present, so the last visible tile is ordinary — the widths are
    /// purely proportional and still sum.
    @Test func proportionalWidthsSumToTheSpace() {
        let bytes = [5, 3, 2]
        let widths = TreemapView.visibleWidths(Self.nodes(bytes), floorLastTile: false,
                                               available: 600, visibleBytes: 10)
        #expect(abs(Self.sum(widths) - 600) < 0.001)
        #expect(abs(widths[0] - 300) < 0.001)
        #expect(abs(widths[2] - 120) < 0.001)
    }

    /// A lone tile takes the row, floored or not — there is nobody to take the width from, and it
    /// must not exceed the space either.
    @Test func aLoneTileTakesTheRowAndNoMore() {
        let widths = TreemapView.visibleWidths(Self.nodes([7]), floorLastTile: true,
                                               available: 500, visibleBytes: 7)
        #expect(widths == [500])

        // And in a row narrower than the floor, the floor does not win: `min(labelMinWidth, …)`.
        let cramped = TreemapView.visibleWidths(Self.nodes([1]), floorLastTile: true,
                                                available: 20, visibleBytes: 1)
        #expect(cramped == [20], "a lone tile overflowed a row narrower than the label floor")
    }

    /// The degenerate inputs a real scan can produce: no tiles, and tiles of zero bytes.
    @Test func emptyAndZeroByteInputsDoNotOverflowOrDivideByZero() {
        #expect(TreemapView.visibleWidths([], floorLastTile: true, available: 900, visibleBytes: 0).isEmpty)

        let zeros = TreemapView.visibleWidths(Self.nodes([0, 0]), floorLastTile: true,
                                              available: 300, visibleBytes: 0)
        #expect(zeros.count == 2)
        #expect(Self.sum(zeros) <= 300.001, "zero-byte tiles summed past the row")
        #expect(zeros.allSatisfy { $0.isFinite }, "a zero denominator produced a non-finite width")
    }

    /// The floor cannot push the siblings negative: with a floor wider than the whole row's share,
    /// the others clamp at zero rather than going negative and inverting the layout.
    @Test func anOversizedFloorClampsTheSiblingsAtZero() {
        let widths = TreemapView.visibleWidths(Self.nodes([1, 1_000_000]), floorLastTile: true,
                                               available: 30, visibleBytes: 1_000_001)
        #expect(widths.allSatisfy { $0 >= 0 }, "a tile was given a negative width")
        #expect(Self.sum(widths) <= 30.001)
    }
}
