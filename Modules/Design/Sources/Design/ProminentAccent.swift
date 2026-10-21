import SwiftUI

// MARK: - Filled system buttons follow the app's accent

/// What a `.borderedProminent` button — or a sheet's default button and radios — is tinted with.
///
/// Untinted, these paint the SYSTEM accent, so a window that follows the app's hue had its main
/// verbs (Run, Merge, Apply, Save…) in the Mac's blue beside a green capsule. Tinted with the RAW
/// accent they follow the hue, but AppKit lays a white label on the fill whatever its colour: 2.66:1
/// on Green. So the tint is the deepened `accentFillColor` — **at `.none` too** (decided
/// 2026-10-21): a filled button is a filled control the app lays a verb on, beside the lit tools and
/// chips that already deepen the Mac's accent, and the stock blue carries white at only 4.02:1. At
/// `.none` it had taken the system accent untouched, as `SegmentedAccent.tint(for:)` still does for
/// a segmented picker, and Fill & Sign showed two blues: its lit tool deepened, Save Filled Copy not.
public enum ProminentAccent {
    /// The fill a prominent or default button takes for `hue`.
    public static func tint(for hue: LiquidGlassHue) -> Color { hue.accentFillColor }
}

public extension View {
    /// Tints this control's fill with `hue`, for a view that is handed the hue.
    func accentedProminent(_ hue: LiquidGlassHue) -> some View {
        tint(ProminentAccent.tint(for: hue))
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
