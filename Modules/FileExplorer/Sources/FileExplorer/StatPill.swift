import SwiftUI
import Design

/// A compact count chip for the differences header: an SF Symbol, the count, and a short
/// label, with the whole capsule tinted so the actionable number stands out.
/// The look is entirely Design's standard `PillVariant`; this wrapper only owns the
/// icon + count + label arrangement and the optional trailing affordance.
struct StatPill: View {
    let count: Int
    let label: String
    let color: Color
    let systemImage: String
    /// Optional affordance symbol at the capsule's trailing edge (e.g. a chevron when the pill
    /// doubles as a button). Nil, the default for the lens workspaces' static pills, delegates to
    /// the shared `Pill`.
    var trailingSystemImage: String? = nil
    /// When set, the pill drops the `color` tint wash entirely and wears a solid capsule instead:
    /// one fill, and text drawn to pair with that fill.
    ///
    /// The differences count pill passes `.onAccent(fill:label:)` here in every state; its
    /// freshness goes on `detailStyle` instead. See `DifferencesView.countPillDressing`, which
    /// owns the rule.
    var semantic: SemanticCapsuleStyle? = nil
    /// A short secondary run after the label, behind a hairline divider ("29m ago" on the
    /// differences count pill). Set in `labelFont` at full `content` strength, never at
    /// `dimmedOnFillOpacity`, which is for non-text indicators (3:1 floor); text needs 4.5:1. Its
    /// smaller size beside the semibold `numberFont` makes it read as secondary.
    var detail: String? = nil
    /// What VoiceOver says in the `detail` run's place, supplied by the caller, since only it
    /// knows what the run means (an age, or "scanning…"). Left nil, the detail is spoken verbatim:
    /// flat, but never untrue.
    var spokenDetail: String? = nil
    /// When set, the `detail` run wears its own capsule inside the pill, in this family. Scoping
    /// the status to the run keeps the pill reading as a control: a whole capsule in a pale
    /// semantic wash beside the accent would read as disabled, not as a warning.
    ///
    /// The run is ringed in the outer capsule's content colour, and the ring is load-bearing: some
    /// fills reach only ~2.7:1 against some accents (`.neutral` on Indigo), but the ring is
    /// `onAccentLabelColor`, which `AccentFill.deepened` keeps ≥4.55:1 against every accent fill.
    ///
    /// `SemanticCapsuleTests` computes the fill/accent pairs, and `StatPillDetailRingTests`
    /// measures the painted edge, which comes out lower because of anti-aliasing. The snapshot
    /// references can't see a 1pt stroke.
    var detailStyle: SemanticCapsuleStyle? = nil

    /// What VoiceOver reads for the whole capsule. Pure and static so the composition can be
    /// asserted directly; the view below is the only production caller.
    static func accessibilityLabel(count: Int, label: String, spokenDetail: String?) -> String {
        let subject = "\(count.formatted()) \(label)"
        guard let spokenDetail, !spokenDetail.isEmpty else { return subject }
        return "\(subject), \(spokenDetail)"
    }

    var body: some View {
        Group {
            // The shared `Pill` covers the plain tinted case. Anything else (a trailing
            // affordance, a flat semantic fill, or both) composes the shared surface directly,
            // Pill's documented escape hatch, with Pill's 5pt spacing and fonts. Keyed on the
            // semantic style too, so the collapsed differences strip, which has no chevron, keeps
            // the same colour language as the header.
            if trailingSystemImage != nil || semantic != nil {
                HStack(spacing: 5) {
                    // No leading icon on the semantic path: the status lives in the detail run,
                    // and the pill leads with the number it is about.
                    if semantic == nil {
                        Image(systemName: systemImage)
                            .scaledFont(PillVariant.standard.iconFont)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(count.formatted())
                        .scaledFont(PillVariant.standard.numberFont)
                        .monospacedDigit()
                        // The roll `Pill` gives the count on the other branch: this path draws
                        // its own `Text`, so it needs the transition here.
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: count)
                    Text(label)
                        .scaledFont(PillVariant.standard.labelFont)
                    if let detail {
                        // A 1pt rule at the content colour's dimmed strength: a non-text
                        // indicator, so it may take `dimmedOnFillOpacity`; the text after it may
                        // not.
                        Rectangle()
                            .fill((semantic?.content ?? PillVariant.labelInk(for: color)).opacity(AccentLabel.dimmedOnFillOpacity))
                            .frame(width: 1, height: 11)
                        Text(detail)
                            .scaledFont(PillVariant.standard.labelFont)
                            .monospacedDigit()
                            // One line always: the header row's height is pinned, and a wrapping
                            // capsule would push the pill past it.
                            .lineLimit(1)
                            .modifier(DetailRunCapsule(style: detailStyle, ring: semantic?.content ?? PillVariant.labelInk(for: color)))
                    }
                    if let trailingSystemImage {
                        Image(systemName: trailingSystemImage)
                            .scaledFont(.system(size: 9, weight: .semibold))
                            // A secondary run on an accent fill dims with `dimmedOnFillOpacity`,
                            // never a local literal, which could drop below the 3:1 floor. The
                            // flat-fill pairs have contrast to spare, so it applies there too.
                            .foregroundStyle((semantic?.content ?? PillVariant.labelInk(for: color)).opacity(AccentLabel.dimmedOnFillOpacity))
                            // Cross-fade the right↔left flip instead of a hard swap, inside
                            // whatever withAnimation the toggling button wraps around the change.
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(semantic?.content ?? PillVariant.labelInk(for: color))
                .modifier(StatPillSurface(semantic: semantic, tint: color))
                .fixedSize()
            } else {
                Pill(.standard, tint: color, systemImage: systemImage, count: count, label: label)
            }
        }
        // One element, not icon and texts: VoiceOver reads "7 Differences", plus the spoken
        // detail when a detail run is present.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(count: count, label: label,
                                                    spokenDetail: spokenDetail ?? detail))
    }
}

/// The `detail` run's own capsule, or the bare run when there is no status to show. Split out for
/// the same reason as `StatPillSurface`: the two branches produce different view types.
///
/// Padding 1pt vertical, 6pt horizontal, smaller than the outer pill's 4/10, so the run nests
/// inside the capsule without pushing the header row taller; `.fixedSize()` on the outer HStack
/// grows the pill by exactly this padding when a status appears.
///
/// Internal, not file-private, so `StatPillDetailRingTests` can render it alone and count the
/// ring's pixels: the snapshot references' tolerance absorbs a missing 1pt ring.
struct DetailRunCapsule: ViewModifier {
    let style: SemanticCapsuleStyle?
    /// The outer capsule's content colour — see `StatPill.detailStyle` for why the ring exists.
    let ring: Color

    func body(content: Content) -> some View {
        if let style {
            content
                .foregroundStyle(style.content)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(style.fill, in: Capsule(style: .continuous))
                .overlay { Capsule(style: .continuous).strokeBorder(ring, lineWidth: 1) }
        } else {
            content
        }
    }
}

/// Either the shared tint wash (`pillSurface`) or a flat semantic fill. Split out because the two
/// produce different view types and a ternary can't choose between them inline.
///
/// Both arms are Design's, so neither drifts on its own; `semanticCapsuleSurface(_:)` lets the
/// Appearance tab's accent preview, which can't import FileExplorer, paint the same pill.
private struct StatPillSurface: ViewModifier {
    let semantic: SemanticCapsuleStyle?
    let tint: Color

    func body(content: Content) -> some View {
        if let semantic {
            content.semanticCapsuleSurface(semantic)
        } else {
            content.pillSurface(.standard, tint: tint)
        }
    }
}
