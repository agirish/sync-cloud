import SwiftUI

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
