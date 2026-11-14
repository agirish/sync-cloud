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

/// The two colors a semantic capsule is built from, for one family and appearance.
///
/// Semantic colors, not the app accent, and flat fills, not tinted glass: an accent-tinted glass
/// capsule over the accent-washed pane header renders lighter than its own backdrop and strands its
/// label near 1.35:1, since a tint over its own hue has nothing to shift against. Being
/// hue-independent also keeps a capsule identical under every `LiquidGlassHue`, including `.green`
/// and `.amber`, which would otherwise collide with the status colors.
///
/// These two families are the app's one definition of these colours, which
/// `DifferencesView.countPillDressing` reads directly; `SemanticCapsuleTests` measures the contrast.
/// The attention family is terracotta, not amber, which goes muddy against the mint/emerald window
/// wash while terracotta still reads as warm.
public struct SemanticCapsuleStyle: Equatable, Sendable {
    /// The capsule fill.
    public let fill: Color
    /// Label and glyphs. In a semantic family, label colour (black in light, white in dark): the
    /// family's colour is the fill, and the words don't carry it a second time. On the accent
    /// path, the fill's paired label.
    public let content: Color

    public init(fill: Color, content: Color) {
        self.fill = fill
        self.content = content
    }

    public static func of(_ family: SemanticCapsuleFamily, _ scheme: ColorScheme) -> SemanticCapsuleStyle {
        let dark = scheme == .dark
        switch family {
        case .attention:
            return dark
                ? SemanticCapsuleStyle(fill: rgb(0.22, 0.11, 0.07),
                                       content: labelInk(dark: true))
                : SemanticCapsuleStyle(fill: rgb(0.97, 0.90, 0.86),
                                       content: labelInk(dark: false))
        case .neutral:
            return dark
                ? SemanticCapsuleStyle(fill: rgb(0.16, 0.18, 0.23),
                                       content: labelInk(dark: true))
                : SemanticCapsuleStyle(fill: rgb(0.86, 0.89, 0.95),
                                       content: labelInk(dark: false))
        }
    }

    /// A capsule that wears the app's accent hue instead of a semantic family: the differences
    /// count pill's treatment.
    ///
    /// The trade: an accent capsule is hue-dependent, so unlike `.attention` it can't carry meaning
    /// by colour. In exchange it reads as a control, which the pill needs and a pale wash can't
    /// give.
    ///
    /// - Parameters:
    ///   - fill: the accent fill, from `LiquidGlassHue.accentFillColor`: the deepened accent, not
    ///     the raw one, since this capsule carries a white label. Passed in so `Design` needs no
    ///     opinion about which hue is in play.
    ///   - label: its paired label colour, from `LiquidGlassHue.onAccentLabelColor`.
    public static func onAccent(fill: Color, label: Color) -> SemanticCapsuleStyle {
        SemanticCapsuleStyle(fill: fill, content: label)
    }

    /// A family capsule's words: label colour for the appearance, as plain colours rather than
    /// `.primary` so the style stays a value its tests can measure without a view.
    private static func labelInk(dark: Bool) -> Color { dark ? .white : .black }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}

public extension View {
    /// The flat semantic-capsule surface: `PillVariant.standard`'s geometry with a solid
    /// `SemanticCapsuleStyle` fill in place of `pillSurface(_:tint:)`'s 14% tint wash.
    ///
    /// Shared so the differences count pill (`StatPill`) and the Appearance tab's accent preview
    /// paint the same capsule; a lookalike with its own paddings would let the preview drift from
    /// what ships.
    ///
    /// Surface only: the caller sets `style.content` itself, because only it knows which runs are
    /// non-text indicators allowed `AccentLabel.dimmedOnFillOpacity` and which are text.
    func semanticCapsuleSurface(_ style: SemanticCapsuleStyle) -> some View {
        padding(.horizontal, PillVariant.standard.horizontalPadding)
            .padding(.vertical, PillVariant.standard.verticalPadding)
            .background(style.fill, in: Capsule(style: .continuous))
    }
}
