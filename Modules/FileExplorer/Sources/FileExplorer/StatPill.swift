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
    /// When set, a status dot in this colour replaces the leading SF Symbol, and `color` — the
    /// capsule's own tint — stays the app accent.
    ///
    /// This is the freshness pill's rule (`DashboardViews.freshnessPill`) applied to a count:
    /// painting the whole capsule in a semantic colour made it the one non-accent surface in the
    /// chrome, reading as a colour clash rather than as a status. Moving the semantics to the dot
    /// keeps the header monochrome in the accent without losing them. Only the geometry differs
    /// from the freshness pill — the ring is drawn in the pill's tint here, since this capsule is
    /// a 14% wash rather than a near-solid accent fill.
    var statusColor: Color? = nil

    var body: some View {
        Group {
            if let trailingSystemImage {
                // Heterogeneous content (count + label + a trailing affordance) composes the
                // shared surface directly — Pill's documented escape hatch — using Pill's own
                // 5pt spacing and variant fonts so the two branches render identically.
                HStack(spacing: 5) {
                    if let statusColor {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(color.opacity(0.55), lineWidth: 1))
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
                        .foregroundStyle(color.opacity(0.75))
                        // Cross-fade the right↔left flip instead of a hard swap; runs inside
                        // whatever withAnimation the toggling button wraps around the state change.
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(color)
                .pillSurface(.standard, tint: color)
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
