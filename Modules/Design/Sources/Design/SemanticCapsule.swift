import SwiftUI

/// Which meaning a semantic capsule is carrying. Deliberately about the *message*, not the
/// surface: two capsules saying "this may need your attention" should look identical whether the
/// thing wanting attention is a stale scan or something else entirely.
public enum SemanticCapsuleFamily: String, CaseIterable, Sendable {
    /// Something is out of date or waiting on you. Terracotta.
    case attention
    /// Information with no verdict attached. Slate.
    case neutral
}

/// The three colors a semantic capsule is built from, for one family and appearance.
///
/// These are SEMANTIC colors, not the app accent, and flat fills rather than tinted glass. Both
/// choices were forced by measurement on the pane header's old freshness badge: an accent-tinted
/// glass capsule over the accent-washed header rendered LIGHTER than its own backdrop, stranding
/// its label at 1.35:1 — a tint composited over its own hue has nothing to shift against. Being
/// hue-independent also means a capsule renders identically under all twelve `LiquidGlassHue`
/// cases, including the two (`.green`, `.amber`) that would otherwise collide with the very colors
/// carrying the status.
///
/// These two families are the app's ONE definition of these colours. Scan freshness used to keep
/// its own `FreshnessStyle` triad per state, which was three-quarters duplication — `stale` already
/// delegated here and `scanning` was a verbatim copy of `.neutral` — and exactly the "two warms
/// that nearly match" drift this type exists to prevent. `DifferencesView.countPillDressing` now
/// reads these directly. `SemanticCapsuleTests` measures the contrast rather than trusting a
/// comment.
///
/// The family is terracotta, not the amber it started as. Amber's yellow cast went muddy against
/// the mint/emerald window wash — the earthier red-orange reads as a deliberate choice there while
/// still being unmistakably warm, i.e. still saying "this wants your attention". The move also
/// bought contrast: the light pair went 6.8:1 → 7.7:1 and its dot 3.6:1 → 4.2:1.
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
    /// A ring drawn around the dot, or nil for no ring.
    ///
    /// Non-nil only on the `onAccent(fill:label:)` path, and load-bearing there: on a saturated
    /// accent fill NOTHING coloured can clear the 3:1 floor for a non-text indicator. Measured, a
    /// bare terracotta dot lands between 1.01:1 (Graphite) and 1.69:1 (Cyan) across the eleven
    /// fixed hues — the accents all sit mid-luminance, so there is no room on either side. Green at
    /// L = 0.34 puts 3:1 at L < 0.081 or L > 0.87, i.e. darker than this terracotta and lighter than
    /// a pale peach, and even a pure white dot only reaches 2.7:1 there. So the ring carries the
    /// separation (it is the fill's own label colour, hence ≥3:1 against it by construction) and the
    /// dot is free to just carry the hue.
    public let dotRing: Color?

    public init(fill: Color, content: Color, dot: Color, dotRing: Color? = nil) {
        self.fill = fill
        self.content = content
        self.dot = dot
        self.dotRing = dotRing
    }

    public static func of(_ family: SemanticCapsuleFamily, _ scheme: ColorScheme) -> SemanticCapsuleStyle {
        let dark = scheme == .dark
        switch family {
        case .attention:
            return dark
                ? SemanticCapsuleStyle(fill: rgb(0.22, 0.11, 0.07),
                                       content: rgb(1.00, 0.72, 0.58),
                                       dot: rgb(0.95, 0.45, 0.25))
                : SemanticCapsuleStyle(fill: rgb(0.97, 0.90, 0.86),
                                       content: rgb(0.48, 0.18, 0.07),
                                       // Deliberately darker than "system orange": at that
                                       // saturation the dot measured 2.3:1 on its own fill and
                                       // failed the 3:1 floor for non-text indicators.
                                       dot: rgb(0.73, 0.29, 0.13))
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

    /// A capsule that wears the app's accent hue instead of a semantic family, with an attention
    /// dot on top: the differences count pill's treatment.
    ///
    /// The trade this makes, stated plainly because it reverses the reasoning above: an accent
    /// capsule is hue-DEPENDENT, so it cannot carry meaning by colour the way `.attention` does.
    /// What it gets in exchange is reading as a control, which the pill needs and a pale wash never
    /// managed. The dot is what keeps the "wants your attention" signal, which is why it stays
    /// terracotta and gets a ring.
    ///
    /// - Parameters:
    ///   - fill: the accent fill, from `LiquidGlassHue.accentFillColor` — the DEEPENED accent, not
    ///     the raw one, since this capsule carries a white label. Passed in rather than derived here
    ///     so `Design` needs no opinion about which hue is in play.
    ///   - label: its paired label colour, from `LiquidGlassHue.onAccentLabelColor`.
    public static func onAccent(fill: Color, label: Color) -> SemanticCapsuleStyle {
        SemanticCapsuleStyle(fill: fill, content: label, dot: attentionDotOnAccent, dotRing: label)
    }

    /// The attention dot as it appears on a saturated accent fill: brighter than the `.attention`
    /// family's own dot, which is tuned to sit on that family's pale cream and would read as a mud
    /// spot on mid-luminance emerald. Not a second terracotta any more than the light and dark
    /// variants above are two colours — one family, valued for the backdrop it lands on.
    ///
    /// Appearance-independent by design: the accent fill IS this dot's background, so the window's
    /// light/dark mode never enters into it (same reasoning as `Color.onFillLabel(_:)`).
    public static let attentionDotOnAccent = rgb(0.89, 0.38, 0.17)

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
