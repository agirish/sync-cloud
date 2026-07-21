import SwiftUI

// Which card is which — the four card/surface modifiers at a glance:
//
// - `lensCard`          — a content card INSIDE a lens (a duplicate group, a filing
//                         suggestion, an automation rule row). Defined here.
// - `surfaceCard`       — a pane's whole surface when the workspace is in Cards mode.
// - `bottomSectionCard` — the bottom-workspace section container, styled per `SurfaceStyle`.
// - `glassCardStyle`    — floating overlay chrome (dialogs, popover-like panels).
//
// Testing note: recipe modifiers (searchFieldSurface, CloseButton) are deliberately NOT pinned by
// tests — one-liner compositions whose look is easiest to verify visually and cheap to change.
// `lensCard` is the exception now that its hairline is appearance-dependent (`CardHairline`): it's
// pinned in DesignSnapshotTests alongside the other glass surfaces so a light/dark regression can't
// slip through. Token TYPES (PillVariant, ListDensityMetrics, SemanticColor) are pinned too.
public extension View {
    /// The one lens-card recipe (C2): every card in the bottom-workspace lenses (duplicate
    /// groups, filing suggestions, risky names, automation rules, dry-run rows, the filing
    /// review card) wears this exact surface — a radius-12 continuous rect, half-opacity
    /// control-background fill, and the shared `CardHairline` (a top-lit white specular edge in
    /// dark so the card reads as lit glass on the deep ground, the faint `.quaternary` rule in
    /// light) — so cards read as one family across lenses, and match the section frames around
    /// them in dark instead of staying a flat gray slab inside a bold border.
    ///
    /// `fillOpacity` exists for state, not styling: a disabled automation rule fades its fill
    /// to 0.25 while keeping the same shape and hairline.
    func lensCard(fillOpacity: Double = 0.5) -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)))
            .modifier(CardHairline(cornerRadius: 12))
    }
}
