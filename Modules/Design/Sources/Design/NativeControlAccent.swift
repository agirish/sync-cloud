import SwiftUI

// MARK: - Native controls follow the app's hue (DS4)
//
// Switches, sliders, checkboxes, radio groups and linear progress bars fill with the accent colour
// their environment carries, which is the Mac's accent unless something sets it. Every native
// control takes the window's hue, switches included, from a root modifier rather than one per
// control.
//
// Where the roots go: every window, and every presentation in one. The accent colour inherits down
// a window's views and stops at a `.sheet` or `.popover`, whose content is a window of its own
// (`aControlInASheetTakesThePresentersHue`). So each scene, hosting view and panel takes
// `nativeControlAccent`, and each presentation's content takes `presentedNativeControlAccent`,
// which carries the presenter's hue across. `AccentFillScanTests` (rule 6) holds both.
//
// Why the accent colour and not `.tint`: `.tint` also reaches every `.bordered` and `.borderless`
// button's label and a menu picker's text, turning words the hue, which measured as low as 2.3:1
// on a button's bezel (`NativeControlAccentTests`). The accent colour reaches the same controls
// and leaves those words in label colour; a button whose words should wear the hue takes
// `buttonWordsTint`, which clears 4.5:1 (`ButtonWordInkTests`). The API is deprecated in favour of
// `.tint`, so it is called once, through `LegacyAccentColor`.
//
// Which colour: a named hue takes its deepened fill (`accentFillColor`), because a checkbox or
// radio draws a white mark on it and white on raw Amber is 2.2:1. The segmented pickers and
// prominent buttons fill with the same colour, so a window is one colour. `.none` takes the Mac's
// accent untouched, as `SegmentedAccent.tint(for:)` does.

/// The one place that decides what a window's native controls are filled with.
public enum NativeControlAccent {
    /// The fill for `hue`: the deepened accent, or nil at `.none`, which leaves the Mac's own in
    /// place (setting `Color.accentColor` would read the very accent being set).
    public static func color(for hue: LiquidGlassHue) -> Color? {
        hue == .none ? nil : hue.accentFillColor
    }
}

public extension View {
    /// Makes every native control in this window (switches, sliders, checkboxes, radios, progress
    /// bars) fill with `hue` instead of the Mac's accent. Apply at a window's or panel's root; it
    /// doesn't reach into a sheet or popover, whose content takes `presentedNativeControlAccent`. A
    /// control's or container's own `.tint(…)` still wins, which is why a raw-accent `.tint` is
    /// named in `AccentFillScanTests` (rule 7).
    func nativeControlAccent(_ hue: LiquidGlassHue) -> some View {
        modifier(NativeControlAccentModifier(color: NativeControlAccent.color(for: hue)))
            .environment(\.nativeControlHue, hue)
    }

    /// The same, for a root handed no hue: reads the stored one, and follows it when it changes.
    func nativeControlAccent() -> some View {
        modifier(StoredHueNativeControlAccent())
    }

    /// The presenting window's hue, carried into a sheet or popover. Apply to the content of every
    /// `.sheet`, `.popover` and the like: a root's accent colour doesn't cross into a presentation,
    /// but an environment value does, so the root hands its hue down as one and this reapplies it.
    /// A sheet under Settings' or Setup's own hue keeps that hue; one with no root above it reads
    /// the stored hue.
    func presentedNativeControlAccent() -> some View {
        modifier(PresentedNativeControlAccent())
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

private struct PresentedNativeControlAccent: ViewModifier {
    @Environment(\.nativeControlHue) private var carried
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    func body(content: Content) -> some View {
        content.nativeControlAccent(carried ?? LiquidGlassHue(rawValue: hueRaw) ?? .blue)
    }
}

/// The hue the nearest `nativeControlAccent` root set — nil above every root.
private struct NativeControlHueKey: EnvironmentKey {
    static let defaultValue: LiquidGlassHue? = nil
}

private extension EnvironmentValues {
    var nativeControlHue: LiquidGlassHue? {
        get { self[NativeControlHueKey.self] }
        set { self[NativeControlHueKey.self] = newValue }
    }
}

/// SwiftUI's accent-colour modifier, reached through a protocol so its deprecation (it points at
/// `.tint`, the wrong tool here) is stated once instead of warned at every build.
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
