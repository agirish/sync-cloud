import SwiftUI

// MARK: - Native controls follow the app's hue (DS4)
//
// Switches, sliders, checkboxes, radio groups and linear progress bars fill with the ACCENT
// COLOUR their environment carries. Nothing in the app set one, so they drew the Mac's accent: a
// blue Tint slider right under the Coral swatch, blue switches on a Green window. The owner's call
// (DS4 = B): every native control takes the window's hue, switches included, from one root
// modifier per window rather than one per control.
//
// **Why the root sets the accent colour and not `.tint`.** Measured offscreen with a red root on
// every control in the app's vocabulary (`NativeControlAccentTests`): `.tint` reaches the
// checkbox, the slider and the radio group — and also every `.bordered` and `.borderless`
// button's LABEL and a menu picker's text, which it turns the hue. Those are words, and the hue as
// words on a button's bezel measured 3.4:1 (deepened Green, dark) and 2.3:1 (raw Green, light) in
// the PDF sheets, where one Cancel button already wears it on purpose (`EditorPDFToolSheetFrame`).
// The accent colour reaches the same controls and leaves the buttons' words in label colour. The
// API is marked deprecated in favour of `.tint` — whose wider reach is exactly what has to be
// avoided here — so it is called through `LegacyAccentColor`, once, in this file.
//
// **Which colour.** A named hue takes its DEEPENED fill (`accentFillColor`): a checkbox and a radio
// draw a white mark on the fill, and white on the raw Amber is 2.2:1. That is also the colour the
// segmented pickers and the prominent buttons beside these controls already fill with, so a window
// is one colour. `.none` takes the Mac's accent untouched — "no app accent" means the stock look,
// as `SegmentedAccent.tint(for:)` decides for the same reason.

/// The one place that decides what a window's native controls are filled with.
public enum NativeControlAccent {
    /// The fill for `hue`: the deepened accent — or nil at `.none`, which leaves the Mac's own in
    /// place rather than setting the accent to `Color.accentColor`, a colour that is itself read
    /// from the accent being set.
    public static func color(for hue: LiquidGlassHue) -> Color? {
        hue == .none ? nil : hue.accentFillColor
    }
}

public extension View {
    /// Makes every native control in this window — switches, sliders, checkboxes, radios, progress
    /// bars — fill with `hue` instead of the Mac's accent. Apply ONCE, at a window's or a panel's
    /// root; a control's own `.tint(…)` (a segmented picker's, a prominent button's) still wins, and
    /// so does a container's — which is why a raw-accent `.tint` over anything but a button is
    /// named in `AccentFillScanTests` (rule 7).
    func nativeControlAccent(_ hue: LiquidGlassHue) -> some View {
        modifier(NativeControlAccentModifier(color: NativeControlAccent.color(for: hue)))
    }

    /// The same, for a root handed no hue: reads the stored one, and follows it when it changes.
    func nativeControlAccent() -> some View {
        modifier(StoredHueNativeControlAccent())
    }
}

private struct NativeControlAccentModifier: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        LegacyAccentColor.apply(color, to: content)
    }
}

private struct StoredHueNativeControlAccent: ViewModifier {
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    func body(content: Content) -> some View {
        content.nativeControlAccent(LiquidGlassHue(rawValue: hueRaw) ?? .blue)
    }
}

/// SwiftUI's accent-colour modifier, reached through a protocol so its deprecation — it points at
/// `.tint`, which is the wrong tool here (see above) — is stated once instead of warned at every
/// build. The witness is the only caller.
private protocol AccentColorApplying {
    static func apply<Content: View>(_ color: Color?, to content: Content) -> AnyView
}

private enum LegacyAccentColorWitness: AccentColorApplying {
    @available(macOS, deprecated: 12.0, message: "Wraps the deprecated accentColor(_:) on purpose — see NativeControlAccent")
    static func apply<Content: View>(_ color: Color?, to content: Content) -> AnyView {
        AnyView(content.accentColor(color))
    }
}

private enum LegacyAccentColor {
    static func apply<Content: View>(_ color: Color?, to content: Content) -> AnyView {
        (LegacyAccentColorWitness.self as AccentColorApplying.Type).apply(color, to: content)
    }
}
