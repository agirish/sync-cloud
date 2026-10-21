import SwiftUI

// MARK: - The hue the user picked, for a view handed no colour

public extension LiquidGlassHue {
    /// The hue stored in Settings ▸ Appearance, read now — `.blue` when nothing is stored, the
    /// default every `@AppStorage(LiquidGlass.hueKey)` read in the app falls back to.
    ///
    /// **What a colour parameter defaults to, never `Color.accentColor`.** That one is the SYSTEM
    /// accent and ignores the hue the user picked, so a caller that forgot to pass the hue drew
    /// the Mac's blue in a green window. A read, not a subscription: a view that has to redraw when
    /// the hue changes holds `@AppStorage(LiquidGlass.hueKey)` or sits in a `StoredHueReader`.
    static func stored(in defaults: UserDefaults = .standard) -> LiquidGlassHue {
        defaults.string(forKey: LiquidGlass.hueKey).flatMap(LiquidGlassHue.init(rawValue:)) ?? .blue
    }
}

/// Hands `content` the stored hue, and draws it again when the hue changes — how a control whose
/// caller passed no tint resolves one (`hoverAffordance`, `chromeHover`, `HoverChevron`,
/// `TextSizeStepper`).
struct StoredHueReader<Content: View>: View {
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlassHue.blue.rawValue
    let content: (LiquidGlassHue) -> Content

    init(@ViewBuilder content: @escaping (LiquidGlassHue) -> Content) {
        self.content = content
    }

    var body: some View {
        content(LiquidGlassHue(rawValue: hueRaw) ?? .blue)
    }
}
