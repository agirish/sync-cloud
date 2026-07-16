import SwiftUI

// Which card is which — the four card/surface modifiers at a glance:
//
// - `lensCard`          — a content card INSIDE a lens (a duplicate group, a filing
//                         suggestion, an automation rule row). Defined here.
// - `surfaceCard`       — a pane's whole surface when the workspace is in Cards mode.
// - `bottomSectionCard` — the bottom-workspace section container, styled per `SurfaceStyle`.
// - `glassCardStyle`    — floating overlay chrome (dialogs, popover-like panels).
//
// Testing note: recipe modifiers (lensCard, searchFieldSurface, CloseButton) are
// deliberately NOT pinned by tests — they are one-liner compositions whose look is easiest
// to verify visually and cheap to change. Token TYPES (PillVariant, ListDensityMetrics,
// SemanticColor) are pinned, because their constants fan out into many call sites.
public extension View {
    /// The one lens-card recipe (C2): every card in the bottom-workspace lenses (duplicate
    /// groups, filing suggestions, risky names, automation rules, dry-run rows, the filing
    /// review card) wears this exact surface — a radius-12 continuous rect, half-opacity
    /// control-background fill, and a quaternary half-point hairline — so cards read as one
    /// family across lenses.
    ///
    /// `fillOpacity` exists for state, not styling: a disabled automation rule fades its fill
    /// to 0.25 while keeping the same shape and hairline.
    func lensCard(fillOpacity: Double = 0.5) -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.5))
    }
}
