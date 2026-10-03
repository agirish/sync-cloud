import SwiftUI

/// Things that arrive (roadmap RD46.11): a count that drops out of its item when a scan finds
/// something, and melts back into it when the count goes to zero.
///
/// Frosted and Clear only — the caller decides by the lens material it sits under
/// (`selectionLensMaterial`), which is `.today` at Solid, under Reduce Transparency and outside
/// any host, so all three keep today's plain appearance. Reduce Motion keeps it instant: the
/// animation goes through `DesignAnimationRule`.
///
/// **Only a change animates.** The motion is keyed on the count's presence changing while the row
/// is on screen, so an item that appears already reporting — the rail drawn for the first time,
/// a workspace switch — shows its badge at rest, exactly as today. And it is keyed on the ROW, not
/// the item: an item that grows a badge pushes its neighbours along, and an animation scoped to the
/// item would leave them jumping out of the way while it grew into the gap.
public enum SelectionLensArrival {
    /// The badge's way in and out: from a seed at the item's leading side, a little short of where
    /// it settles. Reversed, the same path is the melt.
    public static var transition: AnyTransition {
        .modifier(active: Effect(progress: 0), identity: Effect(progress: 1))
    }

    /// The change: the spring the lens's leading edge moves on — a little overshoot, settles once.
    /// One curve both ways: leaving, the overshoot falls after the badge has faded, so what shows
    /// is the item and its neighbours settling, which is right for both.
    public static let curve: Animation = .spring(duration: SelectionLensMotion.Spring.lead.duration,
                                                 bounce: SelectionLensMotion.Spring.lead.bounce)

    /// How far short of its place, towards the item's name, the badge starts.
    static let seedOffset: CGFloat = -10

    /// What a change of presence animates with, honouring Reduce Motion. (Not named `animation`:
    /// `ReduceMotionCoverageScanTests` reads any `.animation(` in the sources as a raw modifier.)
    public static func change(reduceMotion: Bool) -> Animation? {
        DesignAnimationRule.resolve(curve, reduceMotion: reduceMotion)
    }

    struct Effect: ViewModifier {
        let progress: Double

        func body(content: Content) -> some View {
            content
                .scaleEffect(SelectionLensMotion.seedScale + (1 - SelectionLensMotion.seedScale) * progress,
                             anchor: .leading)
                .offset(x: seedOffset * (1 - progress))
                .opacity(progress)
        }
    }
}
