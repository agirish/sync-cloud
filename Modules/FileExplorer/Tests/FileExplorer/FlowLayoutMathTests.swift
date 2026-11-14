import Testing
import Foundation
@testable import FileExplorer

/// Pins ``FlowLayoutMath``, the geometry behind the rule cards' condition-chip flow. Every width is
/// clamped to the container's before line-breaking or placing, or a chip proposed its ideal width
/// (a long `mentionsAll` phrase) would draw past the card border.
@Suite struct FlowLayoutMathTests {

    private let spacing: CGFloat = 5
    private let lineSpacing: CGFloat = 5

    private func place(_ sizes: [CGSize], maxWidth: CGFloat) -> (placements: [FlowLayoutMath.Placement], total: CGSize) {
        FlowLayoutMath.place(sizes: sizes, maxWidth: maxWidth, spacing: spacing, lineSpacing: lineSpacing)
    }

    @Test func overWideChipIsClampedToTheContainer() {
        // A 400 pt chip in a 260 pt card: placed at x = 0, clamped to the container.
        let result = place([CGSize(width: 400, height: 20)], maxWidth: 260)
        #expect(result.placements == [.init(origin: .zero, size: CGSize(width: 260, height: 20))])
        #expect(result.total == CGSize(width: 260, height: 20))
    }

    @Test func everyPlacementStaysInsideTheContainer() {
        // Normal chips around an over-wide one: no trailing edge may pass maxWidth.
        let sizes = [CGSize(width: 60, height: 20), CGSize(width: 500, height: 20),
                     CGSize(width: 80, height: 20), CGSize(width: 200, height: 24)]
        let maxWidth: CGFloat = 220
        let result = place(sizes, maxWidth: maxWidth)
        for placement in result.placements {
            #expect(placement.origin.x + placement.size.width <= maxWidth)
        }
        #expect(result.total.width <= maxWidth)
    }

    @Test func inBoundsChipsWrapExactlyAsBefore() {
        // Chips that all fit keep the greedy left-to-right wrap at their ideal sizes.
        let sizes = [CGSize(width: 100, height: 20), CGSize(width: 100, height: 20),
                     CGSize(width: 100, height: 20)]
        let result = place(sizes, maxWidth: 220)
        #expect(result.placements == [
            .init(origin: .zero, size: sizes[0]),
            .init(origin: CGPoint(x: 105, y: 0), size: sizes[1]),
            .init(origin: CGPoint(x: 0, y: 25), size: sizes[2]),   // breaks to line 2
        ])
        #expect(result.total == CGSize(width: 205, height: 45))
    }

    @Test func unconstrainedProposalKeepsIdealSizes() {
        // sizeThatFits with no width proposal (maxWidth = ∞): nothing clamps, one line.
        let sizes = [CGSize(width: 300, height: 20), CGSize(width: 400, height: 22)]
        let result = place(sizes, maxWidth: .infinity)
        #expect(result.placements.map(\.size) == sizes)
        #expect(result.total == CGSize(width: 705, height: 22))
    }

    @Test func emptyFlowIsZeroSized() {
        let result = place([], maxWidth: 300)
        #expect(result.placements.isEmpty)
        #expect(result.total == .zero)
    }
}
