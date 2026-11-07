import SwiftUI

// Which card is which:
//
// - `lensCard`          — a content card INSIDE a lens (a duplicate group, a filing
//                         suggestion, an automation rule row). Defined here.
// - `surfaceCard`       — a pane's whole surface when the workspace is in Cards mode.
// - `bottomSectionCard` — the bottom-workspace section container, styled per `SurfaceStyle`.
// - `glassCardStyle`    — floating overlay chrome (dialogs, popover-like panels).
//
// Testing: one-liner recipes (searchFieldSurface, CloseButton) aren't pinned by tests; they are
// easiest to check by eye. Neither is `lensCard`'s appearance-dependent hairline (`CardHairline`)
// since Design's snapshot suite retired. Token types (PillVariant, ListDensityMetrics,
// SemanticColor) are pinned.
public extension View {
    /// The one lens-card recipe: every card in the bottom-workspace lenses (duplicate groups,
    /// filing suggestions, risky names, automation rules, dry-run rows, the filing review card)
    /// wears this surface, so cards read as one family. A continuous rounded rect, a half-opacity
    /// control-background fill, and the shared `CardHairline` (a top-lit specular edge in dark, a
    /// faint `.quaternary` rule in light).
    ///
    /// `fillOpacity` is for state, not styling: a disabled automation rule fades its fill to 0.25.
    func lensCard(fillOpacity: Double = 0.5) -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)))
            .modifier(CardHairline(cornerRadius: 12))
    }
}
