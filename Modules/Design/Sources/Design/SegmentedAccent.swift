import SwiftUI

// MARK: - Segmented pickers follow the app's accent
//
// The app has its own accent (`LiquidGlassHue`), and everything it draws itself already honours
// it — the Settings rail's selected row, the accent swatches, every filled chip. The `.segmented`
// pickers on the same screen did not: nothing told AppKit about the app hue, so choosing Cyan
// turned the rail cyan and left Theme / Glass effect / Content surface / Text size / List density
// sitting there in system blue.
//
// `.tint()` is what fixes it, and that is worth stating plainly because the house rule points the
// other way: macOS 26 chrome is normally not steerable from outside, and the standing advice is to
// draw the control yourself. Measured rather than assumed, in a real on-screen window in both
// appearances — `.tint()` DOES repaint a segmented picker's selection. So there is no hand-drawn
// control here, and the native keyboard and VoiceOver behaviour of `NSSegmentedControl` survives.
//
// Two things about that measurement are worth leaving behind, because both cost a while to find:
//
// 1. The selection is invisible to an offscreen render. On macOS 26 the selected segment is a
//    `LiftPortalView` inside a `WindowPortal` — the window server composites it, so it never
//    enters the view's backing store. `cacheDisplay` on the host (or on any subview down to the
//    portal's own hosting view) reports the fill as ZERO painted pixels, for the TINTED and the
//    UNTINTED control alike. A snapshot or pixel test of this control's selection colour therefore
//    cannot be written the way `HoverTintRenderTests` writes one; it only answers on screen, in a
//    window belonging to the frontmost app. That is why the tests beside this file assert the
//    COLOUR CHOICE and the METRICS, and why the paint itself was verified by screen capture.
//
// 2. AppKit picks the label colour, and it always picks WHITE — including on a fill light enough
//    that white is unreadable on it. Captured: raw Amber gives white at 2.24:1, raw Cyan 2.07:1.
//    So the tint passed here must be the DEEPENED `accentFillColor`, never the raw `accentColor`.
//    That is the same pairing the rail row and the filled chips already use, arrived at from the
//    other direction: they choose white deliberately, here white is imposed and the fill has to
//    earn it. `AccentFill` guarantees ≥4.55:1 by construction.
//
//    `.none` is exempt from that, deliberately — see `SegmentedAccent.tint(for:)`. It means "the
//    stock macOS look", so it takes the system accent untouched and inherits Apple's contrast.

/// The one place that decides what a `.segmented` picker's selection is tinted with.
///
/// A named seam rather than a bare `.tint(hue.accentFillColor)` at each call site: the choice
/// between the raw accent and the deepened fill is not obvious, is wrong in a way no offscreen
/// test can catch (see above), and must not be re-litigated per picker.
public enum SegmentedAccent {

    /// The tint a `.segmented` picker takes for `hue`.
    ///
    /// A named hue takes the DEEPENED fill, because AppKit draws the selected segment's label white
    /// unconditionally — even on a fill far too light to carry it, which is what the raw accent
    /// would leave on Amber (2.24:1) and Cyan (2.07:1).
    ///
    /// **`.none` is the deliberate exception: it takes the RAW system accent, undeepened.** The
    /// whole meaning of `.none` in the accent picker is "no app accent — the stock macOS look", and
    /// `LiquidGlassHue.none.accentColor` IS `Color.accentColor`, so handing it over untouched makes
    /// the control identical to the one macOS would draw by itself. Deepening it instead — which is
    /// what this did first — bought AA contrast at the cost of the one thing the setting is FOR:
    /// the selection came out about 7% darker than a stock control (system blue (0, 0.478, 1.0) →
    /// (0, 0.445, 0.933)), which is a change to the appearance of "no change".
    ///
    /// The cost of the exception, stated plainly so it is not rediscovered as a bug: at `.none` the
    /// white label AppKit imposes sits at whatever contrast Apple ships, measured at **4.02:1** on
    /// the default blue — under the 4.5:1 floor every other filled surface in this app meets. That
    /// is Apple's ratio on Apple's control, and matching the system exactly is the point of the
    /// setting; `theTintCarriesTheWhiteLabelAppKitImposes` therefore holds the eleven named hues to
    /// the floor and excludes this one on purpose rather than by oversight.
    public static func tint(for hue: LiquidGlassHue) -> Color {
        hue == .none ? hue.accentColor : hue.accentFillColor
    }
}

public extension View {
    /// Makes a `.segmented` picker's selection follow the APP's accent instead of the system's.
    ///
    /// Apply it to the picker itself, not to a container: `.tint` inherits through the environment,
    /// and a container would also recolour the toggles, checkboxes and the Tint slider that share
    /// these screens — which is deliberately not wanted.
    func accentedSegments(_ hue: LiquidGlassHue) -> some View {
        tint(SegmentedAccent.tint(for: hue))
    }
}
