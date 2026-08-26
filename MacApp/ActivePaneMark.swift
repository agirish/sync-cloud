import SwiftUI
import Design

/// **Marks the pane the user is working in — on that pane's own card edges.**
///
/// Which pane a sidebar row opens into used to be stated by a `Left | Right` control in the
/// sidebar's header, so confirming the target meant looking away from the panes, up to a corner
/// that was not part of the work — and by a control that could disagree with everything else on
/// screen. The capsules went with `focusedPaneIsLeft`; this puts the answer on the destination
/// itself, where the header above the column now only describes it.
///
/// **The mark is the card border, and that is a correction.** It began as a 2.5pt accent bar across
/// the top of the column, which rendering in place showed to be the wrong object: a pane in
/// `.cards` is not one card but a stack of three — tab strip, header, list — with real gutters
/// between them, so a bar across the top of the *column* floats above the first card, aligned to
/// nothing, reading as a stray rule rather than as a property of the pane. Reported from the
/// running build on 2026-08-24, and visible in a side-by-side render: the bar sits in the gutter
/// between the tab strip and the window chrome and belongs to neither.
///
/// A single ring around the whole column was the other candidate and is worse: its vertical sides
/// cross both gutters, so it reads as a box drawn *around* three cards instead of as those cards
/// being active, and it fights the card language the style exists to express. Bordering every card
/// in the stack was unambiguous in both themes.
///
/// **So the two surface styles are marked by different mechanisms, because they have different
/// objects to mark.** In `.cards` the border comes from `paneCardIfNeeded(accentBorder:)` on each
/// of the column's three cards, and this modifier draws nothing. In `.unified` there are no pane
/// cards at all — the whole panes region is one frame — so the column's own bounds are the only
/// edge there is, and this rings them.
///
/// **Decoration, never layout**, and that is a hard constraint rather than a preference. Both of
/// `PaneHeader`'s rows are pinned by measurement: `PaneHeaderHeightTests` holds the header to
/// `LiquidGlass.headerHeight`, and `PaneBarLadderTests` measures the top row overflowing a 250pt
/// pane by 10.5pt in the state nothing tested. A label in either row would burst a rung — the same
/// thing that file records happening to the search field, which is why the field takes the bar's
/// track instead of a row of its own. A `strokeBorder` draws inside the bounds it is given and
/// costs nothing.
///
/// **It must not read as selection or focus.** Both of those are already spoken for and both live
/// on ROWS: `PaneSelectionWash` tints the selected rows, and the inactive pane dims that same wash.
/// This marks the container's edge instead, so the two signals never occupy the same surface and
/// cannot be confused for one another — an edge on a region says *things land here*, where a wash
/// on a row says *this is current*.
struct ActivePaneMark: ViewModifier {
    let isFocused: Bool
    let accent: Color
    let surfaceStyle: SurfaceStyle

    /// The accent a card should border itself with, or nil for an unmarked pane — the one place
    /// that answers it, so the three `paneCardIfNeeded` calls in a column cannot come to disagree.
    ///
    /// Nil in `.unified` even when the pane IS focused: there the ring below is the mark,
    /// and `paneCardIfNeeded` is a no-op anyway, so a colour here would be silently discarded.
    static func cardAccent(isFocused: Bool, accent: Color, surfaceStyle: SurfaceStyle) -> Color? {
        guard isFocused, surfaceStyle == .cards else { return nil }
        return LiquidGlass.activeBorder(accent)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isFocused, surfaceStyle == .unified {
                    RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                        .strokeBorder(LiquidGlass.activeBorder(accent), lineWidth: LiquidGlass.activeCardBorderWidth)
                        // The half-gutter every card insets itself by, so the ring lands exactly
                        // where a card's edge would be if this style had one.
                        .padding(LiquidGlass.cardInset)
                        // Never a hit target: it lies over the tab strip and the list's edge, and a
                        // 2pt band that swallowed clicks would eat presses on both.
                        .allowsHitTesting(false)
                }
            }
            // A change of target is a state change worth seeing, and it is the only thing on screen
            // that moves when the control is clicked — without it the mark simply appears somewhere
            // else and the eye has nothing to follow.
            //
            // Which is exactly why it goes through `designAnimation`: "the only thing that moves"
            // is the description of something Reduce Motion is asking about. Under the setting the
            // ring still marks the focused pane, it just arrives there instead of travelling.
            .designAnimation(.easeOut(duration: 0.14), value: isFocused)
    }
}
