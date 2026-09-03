import SwiftUI

/// A run of content that is **exactly as wide as it needs, and no wider — but may be made
/// narrower.**
///
/// SwiftUI has no modifier for this shape, which is why it is a `Layout`. The three widths a
/// container reports are ideal, minimum and maximum, and the ordinary tools each get one of them
/// wrong for a row of readouts:
///
/// - a plain run of `.fixedSize()` views has minimum == ideal, so it cannot yield at all. Its row
///   then draws wider than the column it was offered, and a `.frame(maxWidth: .infinity)` ancestor
///   reports that larger width rather than the proposal — which is how `LensHeaderCard` came to
///   paint its scan-root chip and its "Apply" button off *both* edges of the pane at once.
/// - a `ScrollView` fixes the minimum (it will accept any width) and breaks the maximum: it is
///   greedy, so in an `HStack` it soaks up the row's slack like a `Spacer` and starves a flexible
///   sibling. Measured on To File's row 2: the folder-survey sentence, which has room for its full
///   490pt at a 1,400pt card, was cut to 414 at every width and every text size, because the
///   readouts beside it had taken the surplus.
///
/// This reports the content's own width as both ideal and maximum, and zero as its minimum. An
/// `HStack` therefore hands it precisely what the content needs while the row fits, gives the
/// surplus to whichever sibling wants it, and takes width back from here — clipping the tail —
/// only once the row is genuinely over-subscribed. Combined with a lower `layoutPriority` on a
/// sibling, that sibling still yields first; this is the *last* thing to give, before the row would
/// otherwise overflow.
///
/// The content keeps its natural size when squeezed rather than being compressed into the smaller
/// frame, so pills stay legible and the run loses its tail instead — pair it with `.clipped()` (or
/// a scroll view) to decide what the cut looks like.
/// It replaces an `HStack`, so it must lay out **every** subview: a `@ViewBuilder` slot filled with
/// a `Group` of pills arrives here as several subviews, not one. A first draft sized and placed
/// `subviews.first` alone, which reported the width of the leading chip as the whole run's width
/// and left the rest of the pills unplaced — the readouts drew in the wrong place and the prose
/// beside them moved left to meet them.
public struct ShrinkableRun: Layout {

    /// Gap between the run's items — 8 to match the `HStack` this stands in for.
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    /// **The measured run, held for the pass** — every item at its natural size, plus the two
    /// totals derived from them.
    ///
    /// A `Layout` that declares `cache: inout ()` has no cache at all, and this one was measuring
    /// each subview **twice per layout pass**: `naturalSizes` was mapped in `sizeThatFits` and
    /// mapped again in `placeSubviews`, and `sizeThatFits` is itself asked more than once per pass
    /// (the container queries minimum, ideal and maximum). `sizeThatFits(.unspecified)` on a
    /// subview is a full measurement of that subtree — a pill's text, its padding and its capsule —
    /// and this layout sits on every lens header card, which re-lays out on hover, on a drag frame
    /// and on every scan tick.
    ///
    /// Caching is sound here for a reason specific to this layout: the sizes are taken at
    /// `.unspecified`, so they do not depend on the proposal the container happens to be asking
    /// with. There is nothing for a second proposal to invalidate. The only thing that can change
    /// them is the subviews themselves, which is exactly when SwiftUI calls ``updateCache(_:subviews:)``.
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

    /// **Re-measured, not merely re-validated.** The default implementation does exactly this; it
    /// is written out because the correctness of the whole cache rests on it — SwiftUI calls this
    /// when the subviews may have changed, and a subview whose content grew must not be placed at
    /// the width it had before. The saving is within a pass, not across passes.
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
