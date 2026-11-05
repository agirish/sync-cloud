import SwiftUI

/// A run of content exactly as wide as it needs and no wider, but which may be made narrower.
///
/// SwiftUI has no modifier for this, hence a `Layout`. The ordinary tools each get one of the three
/// widths (ideal, minimum, maximum) wrong for a row of readouts:
///
/// - `.fixedSize()` views have minimum == ideal, so they can't yield: the row draws wider than its
///   column, and a `.frame(maxWidth: .infinity)` ancestor reports that larger width, so the content
///   paints off both edges of the pane.
/// - a `ScrollView` accepts any width but is greedy: in an `HStack` it soaks up the row's slack like
///   a `Spacer` and starves a flexible sibling, such as To File's folder-survey sentence.
///
/// This reports the content's own width as ideal and maximum, and zero as minimum. An `HStack`
/// gives it exactly what the content needs while the row fits, gives the surplus to whichever
/// sibling wants it, and takes width back from here only once the row is over-subscribed. A sibling
/// with a lower `layoutPriority` still yields first.
///
/// Squeezed, the content keeps its natural size and the run loses its tail, so pills stay legible;
/// pair it with `.clipped()` (or a scroll view) to decide what the cut looks like. It replaces an
/// `HStack`, so it lays out every subview: a `@ViewBuilder` slot holding a `Group` of pills arrives
/// as several subviews, not one.
public struct ShrinkableRun: Layout {

    /// Gap between the run's items — 8 to match the `HStack` this stands in for.
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    /// The measured run, held for the pass: every item at its natural size, plus two totals.
    ///
    /// Without a cache each subview would be measured several times per pass (`sizeThatFits` is
    /// asked for minimum, ideal and maximum, then `placeSubviews` measures again), and each is a
    /// full subtree measurement on every lens header card, which re-lays out on hover, drag frames
    /// and scan ticks. Sound because the sizes are taken at `.unspecified`, so no proposal can
    /// invalidate them; only the subviews can, which is when SwiftUI calls
    /// ``updateCache(_:subviews:)``.
    public struct Cache {
        /// Each item at its natural size — what the row would be if nothing were squeezing it.
        var naturalSizes: [CGSize]
        /// The run at its natural width: the items plus the gaps between them. Zero for an empty
        /// run, which has no gaps to count and must not be handed a negative gap total.
        var idealWidth: CGFloat
        /// The tallest item — the run's height, squeezed or not.
        var height: CGFloat
    }

    private func measure(_ subviews: Subviews) -> Cache {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return Cache(naturalSizes: [], idealWidth: 0, height: 0) }
        return Cache(
            naturalSizes: sizes,
            idealWidth: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1),
            height: sizes.map(\.height).max() ?? 0)
    }

    public func makeCache(subviews: Subviews) -> Cache { measure(subviews) }

    /// Re-measures rather than re-validating. The default implementation does this too; it is
    /// written out because the cache's correctness rests on it: a subview whose content grew must
    /// not be placed at its old width. The saving is within a pass, not across passes.
    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = measure(subviews)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                             cache: inout Cache) -> CGSize {
        guard !cache.naturalSizes.isEmpty else { return .zero }
        // `nil` is "as much as you like" and must answer the ideal, not infinity — this is the
        // query an `HStack` uses to learn what the run wants, and answering infinity is what makes
        // a `ScrollView` soak up a row's slack.
        let width = min(cache.idealWidth, proposal.width ?? cache.idealWidth)
        return CGSize(width: max(0, width), height: cache.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout Cache) {
        // Every item at its natural width from the leading edge: what a squeeze cuts is the tail,
        // not a little off each pill. The caller clips.
        var x = bounds.minX
        for (subview, size) in zip(subviews, cache.naturalSizes) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: size.width, height: bounds.height))
            x += size.width + spacing
        }
    }
}
