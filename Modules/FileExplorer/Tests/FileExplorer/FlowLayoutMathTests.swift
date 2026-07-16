import Testing
import Foundation
@testable import FileExplorer

/// Pins ``FlowLayoutMath`` — the geometry behind the rule cards' condition-chip flow. The round-5
/// finding: `placeSubviews` proposed each chip its IDEAL width, so one over-wide chip (e.g. a long
/// `mentionsAll` phrase whose single token outgrows even the chip's own 320 pt cap) drew past the
/// card border. Every width must be clamped to the container's before line-breaking or placing.
@Suite struct FlowLayoutMathTests {

    private let spacing: CGFloat = 5
    private let lineSpacing: CGFloat = 5

    private func place(_ sizes: [CGSize], maxWidth: CGFloat) -> (placements: [FlowLayoutMath.Placement], total: CGSize) {
        FlowLayoutMath.place(sizes: sizes, maxWidth: maxWidth, spacing: spacing, lineSpacing: lineSpacing)
    }

    @Test func overWideChipIsClampedToTheContainer() {
        // A rule card ~260 pt wide holding a chip for a long mentions phrase — the chip's ideal
        // width (400 pt) exceeds the card. It must be placed at x = 0 with its width clamped to
        // the container, never proposed its full 400 pt.
        let chip = automationConditionChipText(.mentionsAll(["confidential-quarterly-earnings-restatement-memo"]))
        #expect(chip.count > 40, "the phrase must be long enough to overflow a card")
        let result = place([CGSize(width: 400, height: 20)], maxWidth: 260)
        #expect(result.placements == [.init(origin: .zero, size: CGSize(width: 260, height: 20))])
        #expect(result.total == CGSize(width: 260, height: 20))
    }

    @Test func everyPlacementStaysInsideTheContainer() {
        // Mixed row: normal chips around an over-wide one. No placement's trailing edge may pass
        // maxWidth — the invariant that keeps a chip from drawing past the card border.
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
        // Behavior preservation for the common case: chips that all fit keep the original
        // greedy left-to-right wrap (same origins, ideal sizes untouched).
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
