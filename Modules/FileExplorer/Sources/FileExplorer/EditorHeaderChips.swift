import SwiftUI
import Design

/// The size of every button in a document header, text and PDF alike: the pane bar's 24pt height,
/// since the two headers share a bottom line with the pane header beside them (RO, 2026-11-26).
/// A 13pt glyph and an 11pt word, the pane bar's title size.
enum EditorHeaderChipMetrics {
    static let height: CGFloat = 24
    static let glyph = ScaledFont.system(size: 13, weight: .semibold)
    static let word = ScaledFont.system(size: 11, weight: .semibold)
    /// Either side of a worded chip's contents.
    static let wordedPadding: CGFloat = 9
    /// Between a chip's glyph and its word.
    static let glyphGap: CGFloat = 5

    /// The narrowest rung's bare chip: an 11pt glyph in an 18pt square, the size these chips had
    /// before RO. A 260pt column can't seat four 24pt chips and the mode capsule beside a name, so
    /// the last rung steps down, as the pane bar steps down to its mini pills.
    static let compactHeight: CGFloat = 18
    static let compactGlyph = ScaledFont.system(size: 11, weight: .semibold)
}

private struct EditorHeaderCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by a document header's narrowest rung: its chips and mode capsule draw at their compact
    /// size (``EditorHeaderChipMetrics/compactHeight``). Bare chips only; that rung has no words.
    var editorHeaderCompact: Bool {
        get { self[EditorHeaderCompactKey.self] }
        set { self[EditorHeaderCompactKey.self] = newValue }
    }
}

/// A header button's label: its glyph, and its word while the row's rung keeps it.
///
/// Worded or bare, ``EditorHeaderChipMetrics``, so New Text File, Find, Files and Close read as one
/// set in both headers. Bare, the glyph in a square of the same height, so the row's height doesn't
/// move between rungs. The word never shrinks (`fixedSize`): a short row truncates the file's name,
/// never "New Te…", and buttons never overprint each other.
struct EditorHeaderChipLabel: View {
    let symbol: String
    var word: String?
    @Environment(\.editorHeaderCompact) private var compact

    var body: some View {
        if let word {
            HStack(spacing: EditorHeaderChipMetrics.glyphGap) {
                Image(systemName: symbol)
                    .scaledFont(EditorHeaderChipMetrics.glyph)
                Text(word)
                    .scaledFont(EditorHeaderChipMetrics.word)
                    .lineLimit(1)
            }
            .padding(.horizontal, EditorHeaderChipMetrics.wordedPadding)
            .frame(height: EditorHeaderChipMetrics.height)
            .fixedSize()
        } else {
            let side = compact ? EditorHeaderChipMetrics.compactHeight : EditorHeaderChipMetrics.height
            Image(systemName: symbol)
                .scaledFont(compact ? EditorHeaderChipMetrics.compactGlyph : EditorHeaderChipMetrics.glyph)
                .frame(width: side, height: side)
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
        // No outset: at 24pt the chip is already level with the mode track beside it.
        .chromeGlassGlyphButton(tint: accent, shape: .capsule)
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
