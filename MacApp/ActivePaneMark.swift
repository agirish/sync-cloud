import SwiftUI
import Design

/// Marks the pane the user is working in on that pane's own edges, so a sidebar row's target
/// shows on the destination itself.
///
/// In `.cards` a pane is a stack of three cards (tab strip, header, list), so each borders itself
/// through `paneCardIfNeeded(accentBorder:)` and this draws nothing; one bar or ring around the
/// column would sit in the gutters, aligned to nothing. In `.unified` there are no pane cards, so
/// this rings the column's bounds. Decoration, never layout: `PaneHeaderHeightTests` and
/// `PaneBarLadderTests` pin both header rows, and a label in either would overflow. It marks an
/// edge, not rows, so it can't be mistaken for the selection `PaneSelectionWash` tints.
struct ActivePaneMark: ViewModifier {
    let isFocused: Bool
    let accent: Color
    let surfaceStyle: SurfaceStyle

    /// The accent a card borders itself with, or nil for an unmarked pane. The one place that
    /// answers it, so a column's three `paneCardIfNeeded` calls can't disagree. Nil in `.unified`
    /// even when focused: the ring below is the mark there, and `paneCardIfNeeded` is a no-op.
    static func cardAccent(isFocused: Bool, accent: Color, surfaceStyle: SurfaceStyle) -> Color? {
        guard isFocused, surfaceStyle == .cards else { return nil }
        return LiquidGlass.activeBorder(accent)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isFocused, surfaceStyle == .unified {
                    // Square, not rounded: here the pane is an area of the window's one region,
                    // not a card. At a window corner the region's own clip rounds it.
                    Rectangle()
                        // On the column's own bounds, no inset: `windowRegionFrame` has already
                        // inset by `cardInset`, so the column's outer edges are the outline and the
                        // ring replaces that hairline. A second inset would draw two lines along
                        // every outer edge of the focused pane.
                        .strokeBorder(LiquidGlass.activeBorder(accent), lineWidth: LiquidGlass.activeCardBorderWidth)
                        // Never a hit target: it lies over the tab strip and the list's edge.
                        .allowsHitTesting(false)
                }
            }
            // Animated so the eye can follow the mark to its new pane. Through `designAnimation`,
            // so under Reduce Motion the ring arrives instead of travelling.
            .designAnimation(.easeOut(duration: 0.14), value: isFocused)
    }
}
