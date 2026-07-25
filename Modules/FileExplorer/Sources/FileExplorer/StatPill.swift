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
    /// When set, the pill drops the `color` tint wash entirely and wears a flat capsule instead:
    /// one solid fill, a dot, and text drawn to pair with that fill.
    ///
    /// Two flavors, and the difference is which of them owns the "wants your attention" signal.
    /// `SemanticCapsuleStyle.of(.attention, _)` puts it in the whole capsule — the treatment a stale
    /// freshness badge wears in the pane header above, hue-independent and therefore safe under the
    /// `.amber`/`.green` accents that would otherwise collide with it. `.onAccent(fill:label:)`
    /// gives the capsule to the accent hue and leaves the signal to the ringed terracotta dot; the
    /// differences count pill takes that path, because it is a *button* and reading as one matters
    /// more there than carrying its severity in the fill.
    var semantic: SemanticCapsuleStyle? = nil

    var body: some View {
        Group {
            if let trailingSystemImage {
                // Heterogeneous content (count + label + a trailing affordance) composes the
                // shared surface directly — Pill's documented escape hatch — using Pill's own
                // 5pt spacing and variant fonts so the two branches render identically.
                HStack(spacing: 5) {
                    if let semantic {
                        // The ring is present exactly when the fill is the accent hue, where a
                        // coloured dot cannot reach 3:1 against a mid-luminance backdrop no matter
                        // which colour it is picked to be (see `SemanticCapsuleStyle.dotRing`). On
                        // a flat semantic fill the dot clears the floor on its own and stays bare.
                        // 9pt outer with a 1pt inset border leaves the same 7pt of colour the
                        // unringed dot has, so the two rungs read as one size.
                        Circle()
                            .fill(semantic.dot)
                            .frame(width: semantic.dotRing == nil ? 7 : 9,
                                   height: semantic.dotRing == nil ? 7 : 9)
                            .overlay {
                                if let ring = semantic.dotRing {
                                    Circle().strokeBorder(ring, lineWidth: 1)
                                }
                            }
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
                        // A secondary run on an accent fill must dim with `dimmedOnFillOpacity`,
                        // never a local literal — the old 0.75 was one of the ad-hoc values that
                        // rule exists to stamp out (it drops white-on-Graphite under the 3:1
                        // floor). Applied on the flat-fill path too: those pairs start at 7.7:1
                        // and 9.3:1, so the extra 0.15 of strength buys nothing there.
                        .foregroundStyle((semantic?.content ?? color).opacity(AccentLabel.dimmedOnFillOpacity))
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
