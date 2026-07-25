import SwiftUI
import Design

/// A compact count chip for the differences header: an SF Symbol, the count, and a short
/// label, with the whole capsule tinted so the actionable number stands out.
/// The look is entirely Design's standard `PillVariant` (C1); this wrapper only owns the
/// icon + count + label arrangement and the optional trailing affordance.
struct StatPill: View {
    let count: Int
    let label: String
    let color: Color
    let systemImage: String
    /// Optional affordance symbol at the capsule's trailing edge (e.g. a chevron when the
    /// pill doubles as a button). Nil — the default, used by Tidy's static pills — delegates
    /// to the shared `Pill`, whose 5pt spacing is 1pt tighter than this pill's original 6pt
    /// (an accepted tightening when the look was unified on Design's variant).
    var trailingSystemImage: String? = nil
    /// When set, the pill drops the `color` tint wash entirely and wears a semantic capsule
    /// instead: a flat fill, a dot, and same-family text.
    ///
    /// This is the freshness badge's treatment (`FreshnessStyle`, and now `SemanticCapsuleStyle`,
    /// which the badge's `stale` values were lifted into) applied to a count. The two say the same
    /// thing — something here may need your attention — and they sit in one window, a pane header
    /// above and the differences bar below, so they should be the same object rather than two
    /// nearly-matching ambers. Semantic colors are also hue-independent, which is what lets this
    /// capsule survive the `.amber` and `.green` accent hues that would otherwise collide with it.
    var semantic: SemanticCapsuleStyle? = nil

    var body: some View {
        Group {
            if let trailingSystemImage {
                // Heterogeneous content (count + label + a trailing affordance) composes the
                // shared surface directly — Pill's documented escape hatch — using Pill's own
                // 5pt spacing and variant fonts so the two branches render identically.
                HStack(spacing: 5) {
                    if let semantic {
                        // No ring around the dot: the freshness badge needs one because its dot
                        // can collide with the accent hue behind it, and this fill is semantic —
                        // there is no accent in the capsule for the dot to sink into.
                        Circle()
                            .fill(semantic.dot)
                            .frame(width: 7, height: 7)
                    } else {
                        Image(systemName: systemImage)
                            .font(PillVariant.standard.iconFont)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(count.formatted())
                        .font(PillVariant.standard.numberFont)
                        .monospacedDigit()
                    Text(label)
                        .font(PillVariant.standard.labelFont)
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle((semantic?.content ?? color).opacity(0.75))
                        // Cross-fade the right↔left flip instead of a hard swap; runs inside
                        // whatever withAnimation the toggling button wraps around the state change.
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(semantic?.content ?? color)
                .modifier(StatPillSurface(semantic: semantic, tint: color))
                .fixedSize()
            } else {
                Pill(.standard, tint: color, systemImage: systemImage, count: count, label: label)
            }
        }
        // One element, not icon + two texts: VoiceOver reads "7 Differences".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(label)")
    }
}

/// Either the shared tint wash (`pillSurface`) or a flat semantic fill. Split out because the two
/// produce different view types and a ternary can't choose between them inline.
private struct StatPillSurface: ViewModifier {
    let semantic: SemanticCapsuleStyle?
    let tint: Color

    func body(content: Content) -> some View {
        if let semantic {
            content
                .padding(.horizontal, PillVariant.standard.horizontalPadding)
                .padding(.vertical, PillVariant.standard.verticalPadding)
                .background(semantic.fill, in: Capsule(style: .continuous))
        } else {
            content.pillSurface(.standard, tint: tint)
        }
    }
}
