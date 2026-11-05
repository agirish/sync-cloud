import SwiftUI

// MARK: - Filled system buttons follow the app's accent

/// What a `.borderedProminent` button, or a sheet's default button and radios, is tinted with.
///
/// Untinted, these paint the system accent beside the app's hue. Tinted with the raw accent, they
/// carry AppKit's white label at 2.66:1 on Green. So the tint is the deepened `accentFillColor`, at
/// `.none` too: the stock blue carries white at only 4.02:1, and the lit tools and chips beside
/// these buttons already deepen the Mac's accent. `SegmentedAccent.tint(for:)` keeps the raw system
/// accent at `.none`.
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
