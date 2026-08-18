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

    /// A glyph whose COLOUR is the meaning — a destructive control's red — kept legible in both
    /// appearances.
    ///
    /// `label(_:light:)` is wrong for these: it flattens to white in dark, which is exactly right
    /// for chrome whose job is legibility and throws away the one thing this glyph is saying. So
    /// the colour survives, and what changes is its DEPTH in light.
    ///
    /// **Measured, because the obvious version ships a glyph nobody can see.** System red on the
    /// pane bar's `.primary.opacity(0.075)` pill renders (1.000, 0.320, 0.298) on a 0.95 field —
    /// **2.87:1**, under the 3:1 a non-text control carrying meaning needs, while the untinted
    /// glyphs beside it measure 4.84:1 on the same surface. Deepening for light clears it. Dark
    /// needs no help (3.71:1 measured) and must not be deepened: `AccentFill.deepened` never
    /// lightens, so applying it there would push the same red down to ~2.5:1 — fixing one
    /// appearance by breaking the other.
    ///
    /// `PaneBarInkContrastTests` measures both appearances against the floor rather than trusting
    /// any of the numbers in this comment.
    public static func semantic(_ scheme: ColorScheme, _ color: Color) -> Color {
        scheme == .dark ? color : AccentFill.deepened(color)
    }

    /// A semantic colour used as **body text**, kept legible in both appearances.
    ///
    /// `semantic(_:_:)` above is the 3:1 bar a glyph or a non-text control needs; text needs 4.5:1,
    /// and the difference is not academic. `SemanticColor.caution` as a bare `.foregroundStyle` on
    /// the near-white Settings sheet measures **1.38:1** — the People section's one actionable line
    /// was drawn that way — and the fill-target deepening only lifts it to 4.17:1. This clears the
    /// text floor — and dark is LIFTED rather than left alone, which is where this parts company
    /// with `semantic` above. Leaving dark untouched is right for a glyph, whose bar is 3:1 and
    /// which every semantic colour clears; text needs 4.5, and on a 0.13 sheet `move` measures
    /// **3.86:1** while `error` lands exactly on 4.50. Two of six missing a bar the member's own
    /// name promises is not a rounding difference.
    ///
    /// Everywhere else in this app a caution is a **fill behind a wash**, which is the other correct
    /// answer and the one to prefer for anything that is not a sentence. This exists for the
    /// sentences.
    public static func bodyText(_ scheme: ColorScheme, _ color: Color) -> Color {
        scheme == .dark ? AccentFill.lightenedForText(color) : AccentFill.deepenedForText(color)
    }

    /// The optional-tint form, for a control whose dark treatment is not a flat colour but a
    /// *fallback to the standard label hierarchy* — `PaneBreadcrumb`'s root crumb, which without a
    /// tint distinguishes the current folder from its ancestors by `.primary` vs `.secondary`.
    /// Returning nil hands it back to that hierarchy instead of flattening both to one white.
    public static func tint(_ scheme: ColorScheme, light: Color?) -> Color? {
        scheme == .dark ? nil : light
    }
}
