import AppKit
import SwiftUI

/// The ink the app's chrome draws its glyphs and labels in: the pane nav cluster, the action bar's
/// quiet and outline weights.
///
/// Light keeps each control's designed ink. Dark returns full-strength `.primary`, because dark
/// surfaces here carry the window's hue wash, not a neutral dark: on the green hue's pane an accent
/// label measures ~1.4:1, `.secondary` ~2.5:1 and `.primary.opacity(0.75)` ~3.4:1, against white's
/// 4.61:1.
///
/// Only the ink changes. The fill still carries state (hover washes, the disabled opacity), so the
/// `HoverAffordance` ladder is untouched and a disabled control doesn't look live. Dark ink doesn't
/// tint on hover: an accent glyph on an accent wash has nothing to shift against.
public enum ChromeInk {
    /// - Parameter light: the colour this control uses on a light appearance, unchanged.
    public static func label(_ scheme: ColorScheme, light: Color) -> Color {
        scheme == .dark ? .primary : light
    }

    /// A glyph whose colour is the meaning (a destructive control's red), kept legible in both
    /// appearances. `label(_:light:)` would flatten it to white in dark; here the colour survives
    /// and only its depth changes, in light.
    ///
    /// Raw system red on the pane bar's pill is 2.87:1 in light, under the 3:1 a meaningful glyph
    /// needs, so light deepens. Dark clears 3:1 as it is and must not be deepened, which would push
    /// it to ~2.5:1. `PaneBarInkContrastTests` measures both appearances.
    public static func semantic(_ scheme: ColorScheme, _ color: Color) -> Color {
        scheme == .dark ? color : AccentFill.deepened(color)
    }

    /// A semantic colour used as body text, kept legible in both appearances. Text needs 4.5:1,
    /// not the 3:1 `semantic(_:_:)` meets: bare `SemanticColor.caution` on the near-white Settings
    /// sheet is 1.38:1. Light deepens to text depth, and dark is lifted, since `move` misses 4.5:1
    /// on a dark sheet.
    ///
    /// Prefer a fill behind a wash for a caution that isn't a sentence; this is for sentences.
    public static func bodyText(_ scheme: ColorScheme, _ color: Color) -> Color {
        scheme == .dark ? AccentFill.lightenedForText(color) : AccentFill.deepenedForText(color)
    }

    /// `bodyText(_:_:)` decided by the appearance the colour is drawn in, for AppKit text that
    /// holds an `NSColor` across appearance changes. An `NSTextView` keeps its runs' colours
    /// (editable Preview's links), so a colour resolved up front would stay deepened after a switch
    /// to dark.
    public static func bodyText(_ color: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).usingColorSpace(.sRGB)
            }
            guard let srgb = resolved else { return NSColor(color) }
            return dark ? AccentFill.lightened(srgb, to: AccentFill.darkTextLuminance)
                        : AccentFill.deepened(srgb, to: AccentFill.textLuminance)
        })
    }

    /// A button's words in a colour: the `.tint` for a `.bordered` or `.borderless` button, which
    /// draws its tint as the label's text.
    ///
    /// Light deepens to body-text depth (`bodyText`), which clears 4.5:1 on the light bezel for
    /// every hue where the raw hue doesn't. Dark takes label colour, as `label(_:light:)` does: no
    /// shade of every hue clears 4.5:1 on the dark bezel. `ButtonWordInkTests` measures the
    /// rendered bezel. Always pass a colour: an untinted button under a sheet's root tint
    /// (`accentedProminent`) draws its words in the deepened fill, under 4.5:1 in both appearances.
    public static func buttonWords(_ scheme: ColorScheme, _ color: Color) -> Color {
        label(scheme, light: bodyText(scheme, color))
    }

    /// The optional-tint form, for a control whose dark treatment falls back to the standard label
    /// hierarchy: `PaneBreadcrumb`'s root crumb, which tells the current folder from its ancestors
    /// by `.primary` vs `.secondary`. Nil keeps that hierarchy instead of flattening both to white.
    public static func tint(_ scheme: ColorScheme, light: Color?) -> Color? {
        scheme == .dark ? nil : light
    }
}

public extension View {
    /// Tints a `.bordered` or `.borderless` button's words with `color` at a depth that reads on
    /// the bezel (`ChromeInk.buttonWords`, for the appearance it's drawn in). Nil leaves it
    /// untinted. `AccentFillScanTests` refuses the raw hue as a button's `.tint`.
    func buttonWordsTint(_ color: Color?) -> some View {
        modifier(ButtonWordsTint(color: color))
    }
}

private struct ButtonWordsTint: ViewModifier {
    let color: Color?
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.tint(color.map { ChromeInk.buttonWords(colorScheme, $0) })
    }
}
