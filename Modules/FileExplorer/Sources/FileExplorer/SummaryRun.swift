import SwiftUI
import Design

/// One fact on a lens header's summary row, drawn as text rather than a capsule. The row's rule
/// is that a capsule is a control: the focus chips navigate and wear one; readouts such as
/// `10 ready` or `4 unsure` do nothing when clicked, so they are plain text.
///
/// The number isn't tinted: without a `Pill`'s wash, yellow `SemanticColor.caution` text is
/// unreadable on white. The colour goes on the glyph, a non-text indicator held to 3:1, and the
/// words use the label hierarchy: count `.primary`, noun `.secondary`. The same treatment as
/// ``LensWorkspaceView/scannedFolderChip(_:help:)``, so the scope reads as part of the readout.
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
