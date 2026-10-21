import SwiftUI

// MARK: - Filled system buttons follow the app's accent

/// What a `.borderedProminent` button — or a sheet's default button and radios — is tinted with.
///
/// Untinted, these paint the SYSTEM accent, so a window that follows the app's hue had its main
/// verbs (Run, Merge, Apply, Save…) in the Mac's blue beside a green capsule. Tinted with the RAW
/// accent they follow the hue, but AppKit lays a white label on the fill whatever its colour: 2.66:1
/// on Green. So the tint is the one `SegmentedAccent` already chose for the same reason — the
/// deepened `accentFillColor` for a named hue, and at `.none` the system accent untouched, so "no
/// accent" still draws the stock control (see `SegmentedAccent.tint(for:)` for that exception and
/// its cost).
public extension View {
    /// Tints this control's fill with `hue`, for a view that is handed the hue.
    func accentedProminent(_ hue: LiquidGlassHue) -> some View {
        tint(SegmentedAccent.tint(for: hue))
    }

    /// Tints this control's fill with the hue the user picked, read from the stored setting — for a
    /// view that is handed only a colour, or none.
    func accentedProminent() -> some View {
        modifier(StoredHueProminentTint())
    }
}

private struct StoredHueProminentTint: ViewModifier {
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue

    func body(content: Content) -> some View {
        content.accentedProminent(LiquidGlassHue(rawValue: hueRaw) ?? .blue)
    }
}
