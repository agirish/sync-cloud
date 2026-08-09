import SwiftUI
import Design

/// One fact on a lens header's summary row, drawn as **text rather than as a capsule**.
///
/// ## Why this exists
///
/// Organize's summary row had six capsules on it and three of them were buttons. The focus chips —
/// `14 to file`, `3 risky names`, `126 folders to rename` — navigate; `10 ready`, `4 new folders`
/// and `4 unsure` are a readout and do nothing when clicked. Every one of them was a `StatPill`, so
/// they were the same shape, the same size and the same tinted-capsule idiom, and the only way to
/// find out which half was live was to click and see. The scanned-folder chip sat *between* the two
/// groups wearing neither treatment, which made it read as a third, broken kind of button.
///
/// So the row now has one rule: **a capsule is a control.** The focus chips keep theirs and are the
/// only things on the row that wear one; everything else is a run of text.
///
/// ## Why the number is not tinted
///
/// The obvious de-capsuling — keep the semantic colour, drop the wash — makes the row *less*
/// legible, not more. `SemanticColor.caution` is `Color.yellow`, and the 0.14 wash and 0.45 hairline
/// a `Pill` puts behind it are most of what gives yellow text a shape on a white card. Take the
/// capsule away and "4 unsure" is yellow-on-white.
///
/// The colour therefore moves to the glyph, which is a non-text indicator and answers to 3:1 rather
/// than 4.5:1, and the words take the standard label hierarchy: the count at `.primary` because it
/// is the fact, the noun at `.secondary` because it only names it. That is strictly more readable
/// than what it replaces, and it is the same treatment ``TidyView/scannedFolderChip(_:)`` already
/// used — which is why the scope now reads as the first member of the readout instead of an oddity
/// between two groups.
struct SummaryRun: View {
    let count: Int
    /// The noun after the count. Already pluralised by the caller — only the caller knows the rule.
    let label: String
    /// The glyph's tint. The words never take it; see the type's doc comment.
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .scaledFont(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(count.formatted())
                .scaledFont(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
            Text(label)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        // One line always: this rides a row whose height `LensHeaderCard` pins, and a wrapping run
        // would push past it.
        .lineLimit(1)
        .fixedSize()
        // One element, not a glyph and two texts: VoiceOver reads "10 ready", not "checkmark, 10,
        // ready".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(label)")
    }
}

/// The hairline that splits the summary row into its two halves: the focus chips that navigate, and
/// the readout that describes whichever list they landed you on.
///
/// Load-bearing, not decoration. Dropping the readout's capsules separates the two groups by weight,
/// but weight alone is a gradient — the rule is categorical ("left of this line is clickable"), and
/// a line is how you say a categorical thing. It is also what stops the scope from reading as a