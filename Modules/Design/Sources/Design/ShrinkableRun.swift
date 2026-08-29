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

    /// Each item at its natural size — what the row would be if nothing were squeezing it.
    private func naturalSizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                             cache: inout ()) -> CGSize {
        let sizes = naturalSizes(subviews)
        guard !sizes.isEmpty else { return .zero }
        let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1)
        // `nil` is "as much as you like" and must answer the ideal, not infinity — this is the
        // query an `HStack` uses to learn what the run wants, and answering infinity is what makes
        // a `ScrollView` soak up a row's slack.
        let width = min(ideal, proposal.width ?? ideal)
        return CGSize(width: max(0, width), height: sizes.map(\.height).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout ()) {
        // Every item at its natural width from the leading edge: what a squeeze cuts is the tail,
        // not a little off each pill. The caller clips.
        var x = bounds.minX
        for (subview, size) in zip(subviews, naturalSizes(subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: size.width, height: bounds.height))
            x += size.width + spacing
        }
    }
}
