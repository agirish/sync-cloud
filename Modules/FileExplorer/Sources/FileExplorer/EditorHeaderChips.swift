import SwiftUI
import Design

/// **A header button's label: its glyph, and its word while the row's rung keeps it** (TE144).
///
/// Expand's worded label is the pattern — a 10pt semibold glyph and word, 7pt either side, 18pt
/// tall — so New Text File, Find, Files and Close read as one set in both headers. Bare, it is the
/// 11pt glyph in an 18pt square each of them drew before it had a word, so the glyph rung is the
/// row it always was, and the row's height does not move between rungs.
///
/// **The word never shrinks** (`fixedSize`): a row short of its ideal width truncates the file's
/// name, never "New Te…" — the PDF header's actions overprinted each other until theirs was fixed.
struct EditorHeaderChipLabel: View {
    let symbol: String
    var word: String?

    var body: some View {
        if let word {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .scaledFont(.system(size: 10, weight: .semibold))
                Text(word)
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .fixedSize()
        } else {
            Image(systemName: symbol)
                .scaledFont(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
        }
    }
}

/// **Close, the last of a document header's buttons** — "× Close" on the worded rung, × alone on
/// the others (TE144), in both the text header and the PDF one. Its own glass capsule in Frosted and
/// Clear, like Expand's. VoiceOver hears the file's name (``EditorWorkspaceView/closeTitle(name:)``);
/// the tooltip names no key, because ⌘W is Close Tab and File ▸ Close Document has none.
struct EditorCloseChip: View {
    let name: String
    var worded: Bool
    let accent: Color
    let action: () -> Void

    static let word = "Close"

    var body: some View {
        Button(action: action) {
            EditorHeaderChipLabel(symbol: "xmark", word: worded ? Self.word : nil)
        }
        .chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)
        .accessibilityLabel(EditorWorkspaceView.closeTitle(name: name))
        .help("Close this document")
    }
}
