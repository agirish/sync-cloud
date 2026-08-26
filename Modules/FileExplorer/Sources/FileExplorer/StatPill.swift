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
    /// pill doubles as a button). Nil — the default, used by the lens workspaces' static pills — delegates
    /// to the shared `Pill`, whose 5pt spacing is 1pt tighter than this pill's original 6pt
    /// (an accepted tightening when the look was unified on Design's variant).
    var trailingSystemImage: String? = nil
    /// When set, the pill drops the `color` tint wash entirely and wears a solid capsule instead:
    /// one fill, and text drawn to pair with that fill.
    ///
    /// The differences count pill passes `.onAccent(fill:label:)` here in EVERY state. It used to
    /// swap the whole capsule per scan-freshness — accent when fresh, flat `.attention` when stale,
    /// flat `.neutral` while scanning — and that is what `detailStyle` now replaces. See
    /// `DifferencesView.countPillDressing`, which owns the rule and the reasoning.
    var semantic: SemanticCapsuleStyle? = nil
    /// A short secondary run after the label, behind a hairline divider — "29m ago" on the
    /// differences count pill. Set in `labelFont` at full `content` strength, NOT at
    /// `dimmedOnFillOpacity`: that opacity is sanctioned for non-text indicators (the trailing
    /// chevron) against a 3:1 floor, and text answers to 4.5:1. The size difference against the
    /// semibold `numberFont` beside it is what makes it read as secondary.
    var detail: String? = nil
    /// What VoiceOver says in the visual `detail` run's place — supplied by the caller, because
    /// only the caller knows what the run MEANS.
    ///
    /// This label used to build the spoken form itself as "scanned \(detail)", which reads
    /// correctly for an age and is nonsense for anything else: the differences pill puts
    /// "scanning…" in that slot while a scan runs, and VoiceOver announced "576 Differences,
    /// scanned scanning…". A pill cannot infer the grammar of a string it was handed, so it stops
    /// trying. Left nil, the detail is spoken verbatim — flat, but never a sentence that isn't true.
    var spokenDetail: String? = nil
    /// When set, the `detail` run wears its OWN capsule inside the pill, in this family.
    ///
    /// This is where the differences pill's status went. Flipping the whole capsule to a flat
    /// semantic family made the stale state stop reading as a control — on a pill whose entire job
    /// is being clickable, a pale terracotta wash beside a saturated accent reads as *disabled*
    /// rather than as *warning*. Scoping the family to the age run keeps the capsule saying "this
    /// is a toggle" while the run says "and it is old".
    ///
    /// The run is RINGED in the outer capsule's own content colour, and that ring is load-bearing,
    /// not decoration: measured across all twelve hues, a `.neutral` fill on the Indigo accent is
    /// 2.68:1 and `.attention` on it 3.08:1, so the inset fill cannot be relied on to separate
    /// itself from the accent behind it. The ring can — it is `onAccentLabelColor`, which
    /// `AccentFill.deepened` guarantees ≥4.55:1 against every accent fill by construction. Same
    /// trick, and the same reason, as the ring on the dot that used to lead this pill.
    ///
    /// Measured in two places, because the palette arithmetic alone is not enough:
    /// `SemanticCapsuleTests` computes the fill/accent pairs, and `StatPillDetailRingTests` renders
    /// the run and measures the PAINTED edge — which comes out lower than the arithmetic, since the
    /// boundary pixel is an anti-aliased blend. The snapshot references do not cover it; a 1pt
    /// stroke is inside their tolerance.
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
            // The shared `Pill` covers the plain tinted case. Anything that departs from it — a
            // trailing affordance, a flat semantic fill, or both — composes the shared surface
            // directly (Pill's documented escape hatch) using Pill's own 5pt spacing and variant
            // fonts, so every rung renders identically. Keying this on the semantic style too is
            // what lets a NON-toggle pill wear the flat fill: the collapsed differences strip
            // shows the same count as the expanded header and must not switch colour language
            // just because it lost its chevron.
            if trailingSystemImage != nil || semantic != nil {
                HStack(spacing: 5) {
                    // No leading dot on the semantic path. It was there to carry "wants your
                    // attention" on the accent capsule, but `onAccent` hard-codes it terracotta in
                    // every state — so it was a warning that was always on, the same defect
                    // `detailStyle` exists to fix, in miniature. The status now lives entirely in
                    // the age run, and the pill leads with the number it is actually about.
                    if semantic == nil {
                        Image(systemName: systemImage)
                            .scaledFont(PillVariant.standard.iconFont)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(count.formatted())
                        .scaledFont(PillVariant.standard.numberFont)
                        .monospacedDigit()
                        // The same roll `Pill` gives the count on the other branch of this view —
                        // the semantic path draws its own `Text` rather than delegating, so it
                        // needs the transition applied here or the pill would roll its number
                        // only while no status was showing.
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: count)
                    Text(label)
                        .scaledFont(PillVariant.standard.labelFont)
                    if let detail {
                        // Same divider recipe the pane-header freshness badge used before this
                        // readout moved in here: a 1pt rule at the content colour's dimmed
                        // strength. The rule is a non-text indicator, so it may take
                        // `dimmedOnFillOpacity`; the text after it may not.
                        Rectangle()
                            .fill((semantic?.content ?? color).opacity(AccentLabel.dimmedOnFillOpacity))
                            .frame(width: 1, height: 11)
                        Text(detail)
                            .scaledFont(PillVariant.standard.labelFont)
                            .monospacedDigit()
                            // One line always: this rides in a header row whose height is pinned,
                            // and a wrapping capsule would push the pill past it.
                            .lineLimit(1)
                            .modifier(DetailRunCapsule(style: detailStyle, ring: semantic?.content ?? color))
                    }
                    if let trailingSystemImage {
                        Image(systemName: trailingSystemImage)
                            .scaledFont(.system(size: 9, weight: .semibold))
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
                }
                .foregroundStyle(semantic?.content ?? color)
                .modifier(StatPillSurface(semantic: semantic, tint: color))
                .fixedSize()
            } else {
                Pill(.standard, tint: color, systemImage: systemImage, count: count, label: label)
            }
        }
        // One element, not icon + two texts: VoiceOver reads "7 Differences" — or "7 Differences,
        // scanned 29m ago" once a detail run is present, since a divider is not something to speak.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(count: count, label: label,
                                                    spokenDetail: spokenDetail ?? detail))
    }
}

/// The `detail` run's own capsule, or the bare run when there is no status to show. Split out for
/// the same reason as `StatPillSurface`: the two branches produce different view types.
///
/// The vertical padding is 1pt and the horizontal 6pt — deliberately smaller than the outer pill's
/// 4/10, so the run nests inside the capsule instead of straining against it and pushing the header
/// row taller. `.fixedSize()` on the outer HStack means the pill grows by exactly this padding when
/// a status appears.
/// Internal rather than file-private so `StatPillDetailRingTests` can render it in isolation and
/// COUNT the ring's pixels. The snapshot references cannot carry that job: measured, removing the
/// ring entirely still passes `countPillFreshnessStates` at its 0.99/0.98 tolerance, because a 1pt
/// stroke around two small capsules is a smaller share of the frame than the tolerance absorbs.
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
/// Both arms are now Design's, so neither can drift on its own: the flat arm's paddings and capsule
/// moved to `semanticCapsuleSurface(_:)` when the Appearance tab's accent preview needed to paint
/// this same pill from a package that cannot import FileExplorer.
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
