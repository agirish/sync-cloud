import SwiftUI

/// What the freshness badge is currently saying.
enum FreshnessState {
    /// A scan is running right now — outranks fresh/stale, since the age on screen is about to
    /// be replaced and re-scanning is already under way.
    case scanning
    case fresh
    case stale
}

/// The badge's three colors for one state and appearance.
///
/// These are SEMANTIC colors, not the app accent, and they are flat fills rather than tinted
/// glass. Both choices are deliberate and were forced by measurement: an accent-tinted glass
/// capsule sitting on the accent-washed header rendered LIGHTER than its own backdrop
/// (rgb(244,246,249) over rgb(186,204,238)), stranding its label at 1.35:1 — a tint composited
/// over its own hue has nothing to shift against. Being hue-independent also means the badge
/// renders identically under all twelve `LiquidGlassHue` cases, including the two (`.green`,
/// `.amber`) that would otherwise collide with the very colors carrying the status.
///
/// Measured against its own fill, every pair clears WCAG AA (4.5:1) for text — light 7.7:1 fresh,
/// 6.8:1 stale, 9.0:1 scanning; dark 8.7:1, 9.0:1, 8.4:1 — and every dot clears the 3:1 floor for
/// non-text indicators (light 3.9:1 / 3.6:1 / 4.0:1, dark 6.9:1 / 7.1:1 / 4.8:1). The light dots
/// are deliberately DARKER than the obvious "system green / system orange": at those saturations
/// they measured 2.5:1 and 2.3:1 on their own fills and failed that floor.
struct FreshnessStyle {
    /// The capsule fill.
    let fill: Color
    /// Label, glyph and divider — always drawn from the fill's own color family, never plain
    /// black or white, so the badge reads as one object rather than text parked on a swatch.
    let content: Color
    /// The status dot: the most saturated member of the family, since it is the smallest element
    /// and has the least area in which to communicate its hue.
    let dot: Color

    static func of(_ state: FreshnessState, _ scheme: ColorScheme) -> FreshnessStyle {
        let dark = scheme == .dark
        switch state {
        case .fresh:
            return dark
                ? FreshnessStyle(fill: rgb(0.09, 0.20, 0.13),
                                 content: rgb(0.55, 0.88, 0.66),
                                 dot: rgb(0.24, 0.82, 0.42))
                : FreshnessStyle(fill: rgb(0.84, 0.94, 0.87),
                                 content: rgb(0.06, 0.32, 0.20),
                                 dot: rgb(0.10, 0.52, 0.22))
        case .stale:
            return dark
                ? FreshnessStyle(fill: rgb(0.24, 0.15, 0.03),
                                 content: rgb(1.00, 0.77, 0.42),
                                 dot: rgb(1.00, 0.64, 0.14))
                : FreshnessStyle(fill: rgb(0.99, 0.91, 0.78),
                                 content: rgb(0.48, 0.25, 0.00),
                                 dot: rgb(0.72, 0.39, 0.00))
        case .scanning:
            // Neutral, not green: a scan in flight has not yet earned "fresh", and colouring it
            // green would flash a success state before the result is known.
            return dark
                ? FreshnessStyle(fill: rgb(0.16, 0.18, 0.23),
                                 content: rgb(0.76, 0.80, 0.88),
                                 dot: rgb(0.55, 0.60, 0.71))
                : FreshnessStyle(fill: rgb(0.86, 0.89, 0.95),
                                 content: rgb(0.14, 0.22, 0.37),
                                 dot: rgb(0.36, 0.43, 0.57))
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
