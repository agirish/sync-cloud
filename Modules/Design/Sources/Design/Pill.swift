import SwiftUI

/// The one tinted-capsule badge recipe (C1). Every count/status pill in the app draws from
/// these two variants, so tint washes and geometry can't drift view by view:
///
/// - `.standard` — the header stat pill: H10/V4 padding, 0.14 tint fill, 0.45 hairline stroke,
///   bold 11pt icon, semibold 12pt number, 11pt label.
/// - `.mini` — the inline badge: H8/V2 padding, the same 0.14 fill, no stroke, semibold 10pt text.
///
/// `Pill` covers the common icon + one-run-of-text case; heterogeneous content (menus, dots,
/// count + label pairs) composes the same surface via `pillSurface(_:tint:)` plus the variant's
/// font constants. A "neutral" mini is simply `tint: .secondary`.
public enum PillVariant: Equatable, Sendable {
    case standard
    case mini

    /// Fill opacity applied to the tint — shared by both variants (and `StatusBadge`).
    public static let fillOpacity: Double = 0.14
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
    /// Wraps arbitrary pill content in the shared capsule surface: variant padding, tinted fill,
    /// and (standard only) the hairline stroke. `showsFill: false` keeps the geometry but drops
    /// the wash — for "quiet" pills that re-ink on hover.
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

/// The ready-made pill for the common case: an optional SF Symbol plus one run of text,
/// tinted throughout. Numeric text opts into `monospacedDigit` so counts don't jiggle.
public struct Pill: View {
    /// Gap between the pill's runs (icon / number / label). Part of the C1 geometry contract
    /// like the paddings on `PillVariant`: hand-assembled pills that mirror this recipe (the
    /// Log window's level chips) and the snapshot references both bake it in, so a tweak here
    /// is a deliberate, test-visible restyle — not a drive-by.
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

    /// The count + label shape ("7 Differences"): the number set in `numberFont` with
    /// monospaced digits so counts don't jiggle, the label in `labelFont` — the pairing
    /// the header stat pills hand-assemble today.
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
        .foregroundStyle(tint)
        .pillSurface(variant, tint: tint)
        .fixedSize()
    }

    /// The monospaced-digit treatment moved from the `Text` onto the *font* when pill fonts
    /// became scalable: `scaledFont(_:)` has to resolve against the environment, so it returns
    /// a view rather than a `Text`, and `Text.monospacedDigit()` is no longer reachable after it.
    /// `ScaledFont.monospacedDigit()` is the same rendering applied one step earlier.
    private var textView: some View {
        let font = isNumeric ? variant.numberFont : variant.labelFont
        return Text(text)
            .scaledFont(isNumeric ? font.monospacedDigit() : font)
            // **A count that changes should roll, not cut.** The reclaim pill has done this since
            // H5 and its comment sanctions keeping the roll even under Reduce Motion — a numeric
            // content transition is a legible way to show a number moving, not decoration. It
            // never reached the shared component, so every *other* live count in the app — diff
            // totals, duplicate groups, the filing backlog — hard-swapped instead.
            //
            // Both halves are needed and neither works alone: `contentTransition` only says HOW
            // to interpolate, and the change has to be inside an animation for anything to
            // interpolate at all. Scoped by `value:` to the text itself, so nothing else in the
            // pill animates when a count arrives. Non-numeric labels are left alone: rolling a
            // word's glyphs is not the same effect, and reads as a glitch.
            .contentTransition(isNumeric ? .numericText() : .identity)
            .animation(isNumeric ? .easeInOut(duration: 0.35) : nil, value: text)
    }
}
