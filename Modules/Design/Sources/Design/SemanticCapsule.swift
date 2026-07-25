import SwiftUI

/// Which meaning a semantic capsule is carrying. Deliberately about the *message*, not the
/// surface: two capsules saying "this may need your attention" should look identical whether one
/// is a scan-freshness badge and the other a difference count.
public enum SemanticCapsuleFamily: String, CaseIterable, Sendable {
    /// Something is out of date or waiting on you. Amber.
    case attention
    /// Information with no verdict attached. Slate.
    case neutral
}

/// The three colors a semantic capsule is built from, for one family and appearance.
///
/// These are SEMANTIC colors, not the app accent, and flat fills rather than tinted glass. Both
/// choices were forced by measurement on the pane header's freshness badge: an accent-tinted glass
/// capsule over the accent-washed header rendered LIGHTER than its own backdrop, stranding its
/// label at 1.35:1 — a tint composited over its own hue has nothing to shift against. Being
/// hue-independent also means a capsule renders identically under all twelve `LiquidGlassHue`
/// cases, including the two (`.green`, `.amber`) that would otherwise collide with the very colors
/// carrying the status.
///
/// The `.attention` values are the freshness badge's `stale` family verbatim, so a stale badge in
/// a pane header and a difference count in the bar below it are the same object rather than two
/// ambers that nearly match.
///
/// `Modules/Dashboard`'s `FreshnessStyle` is this same recipe with freshness-specific states
/// (it also needs a `scanning` neutral and a `fresh` green). It predates this type by hours and is
/// still settling; folding it in here is the obvious follow-up, and the reason `.attention` copies
/// its numbers rather than inventing new ones. `SemanticCapsuleTests` measures the contrast rather
/// than trusting a comment, so the two can't silently drift into failing pairs.
public struct SemanticCapsuleStyle: Equatable, Sendable {
    /// The capsule fill.
    public let fill: Color
    /// Label and glyphs — always from the fill's own color family, never plain black or white, so
    /// the capsule reads as one object rather than text parked on a swatch.
    public let content: Color
    /// The status dot: the most colorful member of the family, since it is the smallest element
    /// and has the least area in which to communicate its hue. Colorful meaning CHROMA, not HSV
    /// saturation — the dark fill is a near-black brown whose HSV saturation actually exceeds the
    /// bright orange dot's, so that is the wrong yardstick for this rule (`SemanticCapsuleTests`).
    public let dot: Color

    public init(fill: Color, content: Color, dot: Color) {
        self.fill = fill
        self.content = content
        self.dot = dot
    }

    public static func of(_ family: SemanticCapsuleFamily, _ scheme: ColorScheme) -> SemanticCapsuleStyle {
        let dark = scheme == .dark
        switch family {
        case .attention:
            return dark
                ? SemanticCapsuleStyle(fill: rgb(0.24, 0.15, 0.03),
                                       content: rgb(1.00, 0.77, 0.42),
                                       dot: rgb(1.00, 0.64, 0.14))
                : SemanticCapsuleStyle(fill: rgb(0.99, 0.91, 0.78),
                                       content: rgb(0.48, 0.25, 0.00),
                                       // Deliberately darker than "system orange": at that
                                       // saturation the dot measured 2.3:1 on its own fill and
                                       // failed the 3:1 floor for non-text indicators.
                                       dot: rgb(0.72, 0.39, 0.00))
        case .neutral:
            return dark
                ? SemanticCapsuleStyle(fill: rgb(0.16, 0.18, 0.23),
                                       content: rgb(0.76, 0.80, 0.88),
                                       dot: rgb(0.55, 0.60, 0.71))
                : SemanticCapsuleStyle(fill: rgb(0.86, 0.89, 0.95),
                                       content: rgb(0.14, 0.22, 0.37),
                                       dot: rgb(0.36, 0.43, 0.57))
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
