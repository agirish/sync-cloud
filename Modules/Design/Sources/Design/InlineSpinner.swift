import SwiftUI

/// The small indeterminate spinner that rides inside a row, beside a status label.
///
/// `.mini` is the real control size below `.small`, so the glyph is drawn small. Never shrink a
/// `.small` spinner with `scaleEffect`: that resamples what AppKit drew, so it renders softer than
/// the crisp spinners elsewhere.
///
/// The frame matters as much: `.controlSize(.mini)` alone reserves 10×10, while `.small` reserves
/// 16×16, so the frame keeps every row's layout where `.small` would put it.
public struct InlineSpinner: View {

    /// What `.controlSize(.small)` reserves. Measured, not chosen:
    /// `theFootprintMatchesTheRecipeItReplaces` checks it against a real `.small` spinner, so an
    /// AppKit change fails the test instead of disagreeing with this literal.
    static let reservedSide: CGFloat = 16

    public init() {}

    public var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: Self.reservedSide, height: Self.reservedSide)
    }
}
