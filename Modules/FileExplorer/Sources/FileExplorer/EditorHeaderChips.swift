import SwiftUI
import Design

/// A header button's label: its glyph, and its word while the row's rung keeps it.
///
/// Worded, a 10pt semibold glyph and word, 7pt either side, 18pt tall, like Expand's, so New Text
/// File, Find, Files and Close read as one set in both headers. Bare, an 11pt glyph in an 18pt
/// square, so the row's height doesn't move between rungs. The word never shrinks (`fixedSize`): a
/// short row truncates the file's name, never "New Te…", and buttons never overprint each other.
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

/// Close, the last of a document header's buttons, in both the text and PDF headers: "× Close" on
/// the worded rung, × alone on the others. Its own glass capsule, like Expand's. VoiceOver hears the
/// file's name (``EditorWorkspaceView/closeTitle(name:)``); the tooltip names no key, because ⌘W is
/// Close Tab and File ▸ Close Document has none.
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
        .accessibilityInputLabels(EditorSpokenNames.names(word: Self.word, label: EditorWorkspaceView.closeTitle(name: name)))
        .help("Close this document")
    }
}

/// What Voice Control answers to, for a header button whose name is longer than its word. Voice
/// Control matches the name, so "Click Find" may miss a button called "Find in this document". The
/// word is the first name it answers to and the full one the second; VoiceOver still reads the
/// label alone.
enum EditorSpokenNames {
    static func names(word: String, label: String) -> [String] {
        word == label ? [label] : [word, label]
    }
}
