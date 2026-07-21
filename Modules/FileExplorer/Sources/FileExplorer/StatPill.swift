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

    var body: some View {
        Group {
            if let trailingSystemImage {
                // Heterogeneous content (count + label + a trailing affordance) composes the
                // shared surface directly — Pill's documented escape hatch — using Pill's own
                // 5pt spacing and variant fonts so the two branches render identically.
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(PillVariant.standard.iconFont)
                        .symbolRenderingMode(.hierarchical)
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
