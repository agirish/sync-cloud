import SwiftUI

// MARK: - Segmented pickers follow the app's accent
//
// The app's own accent (`LiquidGlassHue`) colours everything it draws; `.segmented` pickers have
// to be told, or they stay system blue beside a cyan rail. `.tint()` does repaint a segmented
// picker's selection on macOS 26, checked on screen in both appearances, so there is no
// hand-drawn control here and `NSSegmentedControl`'s keyboard and VoiceOver behaviour survives.
//
// Two traps:
//
// 1. The selection is invisible to an offscreen render. The selected segment is a
//    `LiftPortalView` inside a `WindowPortal`, composited by the window server, so `cacheDisplay`
//    sees zero painted fill pixels, tinted or not. A pixel test of this colour can't be written the
//    way `HoverTintRenderTests` writes one; it answers only on screen, in the frontmost app's
//    window. So the tests beside this file assert the colour choice and the metrics, and the paint
//    is verified by screen capture.
//
// 2. AppKit always draws the label white, even where white is unreadable: raw Amber gives 2.24:1,
//    raw Cyan 2.07:1. So the tint must be the deepened `accentFillColor`, never the raw
//    `accentColor`; `AccentFill` guarantees at least 4.55:1. The rail row and the filled chips use
//    the same pairing.
//
//    `.none` is exempt on purpose (see `SegmentedAccent.tint(for:)`): it means the stock macOS
//    look, so it takes the system accent untouched.

/// The one place that decides what a `.segmented` picker's selection is tinted with. A named seam,
/// not a bare `.tint(hue.accentFillColor)` per call site, because the raw-versus-deepened choice
/// isn't obvious and goes wrong in a way no offscreen test can catch (see above).
public enum SegmentedAccent {

    /// The tint a `.segmented` picker takes for `hue`.
    ///
    /// A named hue takes the deepened fill, because AppKit draws the selected label white even on a
    /// fill too light to carry it (raw Amber 2.24:1, Cyan 2.07:1).
    ///
    /// `.none` takes the raw system accent, undeepened: it means "no app accent, the stock macOS
    /// look", and `LiquidGlassHue.none.accentColor` is AppKit's `controlAccentColor`, read directly
    /// so a window root's `nativeControlAccent` can't turn it into the window's hue. Deepened, the
    /// selection would come out about 7% darker than a stock control: a change to the look of "no
    /// change".
    ///
    /// The costs, so they aren't mistaken for bugs: at `.none` the white label sits at Apple's
    /// contrast, 4.02:1 on the default blue, under the app's 4.5:1 floor, so
    /// `theTintCarriesTheWhiteLabelAppKitImposes` excludes this hue on purpose. And the self-drawn
    /// accent surfaces on the same page, the rail's selected row (`SettingsLayout`) and the accent
    /// preview (`AccentPreview`), keep the deepened fill, so they sit a shade darker than the
    /// pickers.
    ///
    /// **Don't match them up.** A system-drawn control is what `.none` promises to look like, and
    /// Apple owns its contrast; a surface the app draws owns its own and must clear 4.5:1.
    /// Un-deepening the rail would drop its white label to 4.02:1, and deepening the picker breaks
    /// the stock look. (AppKit paints the segmented lift 1–2% darker than a flat fill of the same
    /// colour, so the two never match exactly anyway.)
    public static func tint(for hue: LiquidGlassHue) -> Color {
        hue == .none ? hue.accentColor : hue.accentFillColor
    }
}

public extension View {
    /// Makes a `.segmented` picker's selection follow the app's accent instead of the system's.
    ///
    /// Apply it to the picker itself, not a container: `.tint` inherits, and on a container it
    /// would also turn every bordered and borderless button's words the hue. The toggles,
    /// checkboxes and sliders beside these pickers take the hue from the window root's
    /// `nativeControlAccent`, which leaves buttons' words alone.
    func accentedSegments(_ hue: LiquidGlassHue) -> some View {
        tint(SegmentedAccent.tint(for: hue))
    }
}
