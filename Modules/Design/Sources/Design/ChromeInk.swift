import SwiftUI

/// The ink the app's chrome draws its glyphs and labels in — the pane nav cluster, the action
/// bar's quiet and outline weights.
///
/// Light keeps exactly what each control was designed with. Dark returns full-strength `.primary`,
/// and the reason is the same one that took the brand tint off the provider name (`e5fdab5`): on a
/// dark appearance this app's surfaces are not dark. They carry the window's hue wash, and every
/// reduced-opacity or accent-coloured ink was tuned against a neutral dark that the app does not
/// actually render. Sampled from the running app at the green hue the pane reads `#4d7f68`, and
/// against it a `.quiet` label drawn in the accent measures about 1.4:1, a `.secondary` label about
/// 2.5:1, and the nav cluster's `.primary.opacity(0.75)` about 3.4:1 — while plain white is 4.61:1.
/// A control whose label you have to hunt for is not quieter, it is broken.
///
/// Deliberately only the INK. State keeps being carried by the fill: a hovered nav pill still
/// washes to the accent, a hovered quiet button still warms toward it, and a disabled control still
/// takes `ActionBarMetrics.disabledOpacity` over the whole capsule. So this brightens the chrome
/// without touching the hover ladder `HoverAffordance` owns, and without letting a disabled control
/// start looking live.
///
/// It also means dark stops tinting the ink on hover. That is the point rather than a casualty:
/// an accent glyph on an accent wash has nothing to shift against — the same trap the freshness
/// badge hit — so on a washed surface the fill is the only honest carrier of the hover anyway.
public enum ChromeInk {
    /// - Parameter light: the colour this control uses on a light appearance, unchanged.
    public static func label(_ scheme: ColorScheme, light: Color) -> Color {
        scheme == .dark ? .primary : light
    }

    /// The optional-tint form, for a control whose dark treatment is not a flat colour but a
    /// *fallback to the standard label hierarchy* — `PaneBreadcrumb`'s root crumb, which without a
    /// tint distinguishes the current folder from its ancestors by `.primary` vs `.secondary`.
    /// Returning nil hands it back to that hierarchy instead of flattening both to one white.
    public static func tint(_ scheme: ColorScheme, light: Color?) -> Color? {
        scheme == .dark ? nil : light
    }
}
