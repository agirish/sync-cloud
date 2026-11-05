import SwiftUI

/// The one tinted-capsule badge recipe. Every count or status pill in the app draws from these two
/// variants, so tint washes and geometry can't drift view by view:
///
/// - `.standard` — the header stat pill: H10/V4 padding, 0.14 tint fill, 0.45 hairline stroke,
///   bold 11pt icon, semibold 12pt number, 11pt label.
/// - `.mini` — the inline badge: H8/V2 padding, the same 0.14 fill, no stroke, semibold 10pt text.
///
/// `Pill` covers icon plus one run of text; other content (menus, dots, count and label pairs)
/// composes the same surface via `pillSurface(_:tint:)` and the variant's fonts. A neutral mini is
/// `tint: .secondary`.
public enum PillVariant: Equatable, Sendable {
    case standard
    case mini

    /// Fill opacity applied to the tint — shared by both variants (and `StatusBadge`).
    public static let fillOpacity: Double = 0.14

    /// What a coloured pill's words and glyph are drawn in: label colour, never the tint.
    ///
    /// A word in its own colour on a wash of that colour is unreadable in light (yellow 1.4:1, red
    /// about 2.8:1, against the 4.5:1 text needs). So the colour lives only in the wash, the
    /// standard variant's hairline and any separate dot, and the word is `.primary`. A neutral pill
    /// (`tint: .secondary`, or `SemanticColor.neutral`'s grey, the log's DEBUG) keeps its quieter
    /// secondary ink, or DEBUG would read as loud as ERROR beside it.
    ///
    /// Every pill drawn from these parts takes its ink here, and so does each hand-built one on a
    /// coloured wash; `PillLabelInkScanTests` holds the app's sources to it.
    public static func labelInk(for tint: Color) -> Color {
        tint == .secondary || tint == SemanticColor.neutral ? .secondary : .primary
    }
    /// Stroke opacity of the standard variant's hairline border.
    public static let strokeOpacity: Double = 0.45
    /// Stroke width of the standard variant's hairline border.
    public static let strokeWidth: CGFloat = 0.5

    public var horizontalPadding: CGFloat { self == .standard ? 10 : 8 }
    public var verticalPadding: CGFloat { self == .standard ? 4 : 2 }
    /// Only the standard pill carries the hairline border; minis stay a soft wash.
    public var hasStroke: Bool { self == .standard }

    /// Font for a leading SF Symbol.
    public var iconFont: ScaledFont {
        self == .standard ? .system(size: 11, weight: .bold) : .system(size: 10, weight: .semibold)
    }
    /// Font for the number in a count pill (pair with `.monospacedDigit()`).
    public var numberFont: ScaledFont {
        self == .standard ? .system(size: 12, weight: .semibold) : .system(size: 10, weight: .semibold)
    }
    /// Font for the word(s) after the number, or a mini's whole text.
    public var labelFont: ScaledFont {
        self == .standard ? .system(size: 11) : .system(size: 10, weight: .semibold)
    }
}

public extension View {
    /// Wraps pill content in the shared capsule surface: variant padding, tinted fill, and
    /// (standard only) the hairline stroke. `showsFill: false` keeps the geometry but drops the
    /// wash, for quiet pills that re-ink on hover.
    @ViewBuilder
    func pillSurface(_ variant: PillVariant, tint: Color, showsFill: Bool = true) -> some View {
        let padded = self
            .padding(.horizontal, variant.horizontalPadding)
            .padding(.vertical, variant.verticalPadding)
            .background(Capsule(style: .continuous)
                .fill(tint.opacity(showsFill ? PillVariant.fillOpacity : 0)))
        if variant.hasStroke {
            padded.overlay(Capsule(style: .continuous)
                .strokeBorder(tint.opacity(PillVariant.strokeOpacity), lineWidth: PillVariant.strokeWidth))
        } else {
            padded
        }
    }
}

/// The ready-made pill: an optional SF Symbol plus one run of text, the tint in the wash and the
/// words in label colour (`PillVariant.labelInk(for:)`). Numeric text takes `monospacedDigit` so
/// counts don't jiggle.
public struct Pill: View {
    /// Gap between the pill's runs (icon / number / label). Part of the geometry contract, like the
    /// paddings on `PillVariant`: hand-built pills that mirror this recipe (the Log window's level
    /// chips) and the snapshot references bake it in, so changing it is a deliberate restyle.
    public static let contentSpacing: CGFloat = 5

    private let variant: PillVariant
    private let tint: Color
    private let systemImage: String?
    private let text: String
    private let isNumeric: Bool
    /// Trailing word(s) after a numeric `text` — the "Differences" of "7 Differences".
    private let label: String?

    public init(_ variant: PillVariant, tint: Color, systemImage: String? = nil,
                text: String, isNumeric: Bool = false) {
        self.variant = variant
        self.tint = tint
        self.systemImage = systemImage
        self.text = text
        self.isNumeric = isNumeric
        self.label = nil
    }

    /// The count and label shape ("7 Differences"): the number in `numberFont` with monospaced
    /// digits, the label in `labelFont`, the pairing the header stat pills use.
    public init(_ variant: PillVariant, tint: Color, systemImage: String? = nil,
                count: Int, label: String) {
        self.variant = variant
        self.tint = tint
        self.systemImage = systemImage
        self.text = count.formatted()
        self.isNumeric = true
        self.label = label
    }

    public var body: some View {
        HStack(spacing: Self.contentSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledFont(variant.iconFont)
                    .symbolRenderingMode(.hierarchical)
            }
            textView
            if let label {
                Text(label)
                    .scaledFont(variant.labelFont)
            }
        }
        .foregroundStyle(PillVariant.labelInk(for: tint))
        .pillSurface(variant, tint: tint)
        .fixedSize()
    }

    /// Monospaced digits go on the font, not the `Text`: `scaledFont(_:)` resolves against the
    /// environment and returns a view, so `Text.monospacedDigit()` is unreachable after it.
    /// `ScaledFont.monospacedDigit()` renders the same, one step earlier.
    private var textView: some View {
        let font = isNumeric ? variant.numberFont : variant.labelFont
        return Text(text)
            .scaledFont(isNumeric ? font.monospacedDigit() : font)
            // A count that changes rolls rather than cuts, even under Reduce Motion: a numeric
            // content transition is a legible way to show a number moving, not decoration.
            //
            // Both halves are needed: `contentTransition` says how to interpolate, and the change
            // has to be inside an animation for anything to interpolate. Scoped by `value:` to the
            // text, so nothing else in the pill animates. Non-numeric labels don't roll; rolling a
            // word's glyphs reads as a glitch.
            .contentTransition(isNumeric ? .numericText() : .identity)
            .animation(isNumeric ? .easeInOut(duration: 0.35) : nil, value: text)
    }
}
