import SwiftUI

/// The small indeterminate spinner that rides inside a row, beside a status label.
///
/// Three sites wrote `ProgressView().controlSize(.small).scaleEffect(0.7)` verbatim, and the
/// `scaleEffect` is the problem rather than the size: it **resamples** the spinner AppKit already
/// drew, so those three render softer than the `.controlSize(.small)` spinners a few files over,
/// which are drawn crisp at their own size. Two spinners in one app should not differ in sharpness
/// because one of them was scaled after the fact.
///
/// `.mini` is the real control size just below `.small`, so the glyph is *drawn* small rather than
/// shrunk — same intent as the old recipe, without the resample.
///
/// **The frame is the load-bearing half, and measuring is what found that.** `scaleEffect` is a
/// render-time transform: it does not change layout, so the old recipe **reserved 16×16 and drew at
/// ~11**. A bare `.controlSize(.mini)` reserves 10×10 — so the obvious swap would have quietly
/// pulled three status rows in by 6pt while claiming to be a sharpness fix. Framing the mini
/// spinner back to what `.small` reserves keeps every row exactly where it is and changes only what
/// the defect was ever about: whether the pixels were drawn at this size or resampled down to it.
public struct InlineSpinner: View {

    /// What `.controlSize(.small)` reserves, and therefore what the three converted rows already
    /// allowed for. Measured, not chosen — `theFootprintMatchesTheRecipeItReplaces` pins it against
    /// the recipe itself rather than against this number, so a future AppKit change fails the test
    /// instead of silently disagreeing with a literal.
    static let reservedSide: CGFloat = 16

    public init() {}

    public var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: Self.reservedSide, height: Self.reservedSide)
    }
}
